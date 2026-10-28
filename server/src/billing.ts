import Stripe from "stripe";
import type { Config } from "./config";
import { isSubscriptionActive, subscriptionState } from "./entitlements";
import { ApiError } from "./errors";
import { errorName, log } from "./log";
import type { Platform } from "./platform";
import { withRetries } from "./retry";

/** Stripe istemcisi (dış sistem bağlantısı): fetch tabanlı; yeniden denemeyi `withRetries` yapar. */
export function stripeClient(platform: Platform, config: Config): Stripe {
  return new Stripe(config.secrets.stripe, {
    httpClient: Stripe.createFetchHttpClient(platform.fetch),
    maxNetworkRetries: 0,
    timeout: 20_000,
  });
}

/** Stripe bağlantı, hız sınırı ve sunucu hataları geçicidir. Saf fonksiyondur. */
export function isRetryableStripeError(error: unknown): boolean {
  if (error instanceof Stripe.errors.StripeConnectionError || error instanceof Stripe.errors.StripeRateLimitError) {
    return true;
  }
  return error instanceof Stripe.errors.StripeAPIError && (error.statusCode ?? 0) >= 500;
}

/** Stripe çağrısını yeniden denemeyle yapar; başarısızlıkta mesaj taşımayan istemci hatası fırlatır. */
async function callStripe<T>(platform: Platform, operation: string, userId: string, call: () => Promise<T>): Promise<T> {
  try {
    return await withRetries({ service: "stripe", attempts: 3, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableStripeError }, call);
  } catch (error: unknown) {
    const status: number | null = error instanceof Stripe.errors.StripeError ? (error.statusCode ?? null) : null;
    const requestId: string | null = error instanceof Stripe.errors.StripeError ? (error.requestId ?? null) : null;
    log("error", "stripe_failed", { operation, userId, status, requestId, error: errorName(error) });
    throw new ApiError("upstream_unavailable", "Ödeme servisine ulaşılamadı; biraz sonra yeniden dene.");
  }
}

/** Kullanıcının Stripe müşterisi; yoksa oluşturulur ve saklanır (sonraki ödemelerde yeniden kullanılır). */
async function customerId(db: D1Database, stripe: Stripe, platform: Platform, userId: string): Promise<string> {
  const existing: { stripe_customer_id: string } | null = await db
    .prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?")
    .bind(userId)
    .first<{ stripe_customer_id: string }>();
  if (existing !== null) {
    return existing.stripe_customer_id;
  }
  const customer: Stripe.Customer = await callStripe(platform, "customers.create", userId, () =>
    stripe.customers.create({ metadata: { user_id: userId } }, { idempotencyKey: `customer-${userId}` }),
  );
  await db
    .prepare("INSERT OR IGNORE INTO stripe_customers (user_id, stripe_customer_id, created_at) VALUES (?, ?, ?)")
    .bind(userId, customer.id, platform.now().getTime())
    .run();
  const stored: { stripe_customer_id: string } | null = await db
    .prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?")
    .bind(userId)
    .first<{ stripe_customer_id: string }>();
  if (stored === null) {
    throw new ApiError("internal_error", "Stripe müşterisi kaydedilemedi.");
  }
  return stored.stripe_customer_id;
}

/** Aylık abonelik için Stripe Checkout oturumu (otomatik vergi açık, müşteri yeniden kullanılır); ödeme adresini döndürür. */
export async function createCheckout(db: D1Database, platform: Platform, config: Config, userId: string): Promise<string> {
  if (isSubscriptionActive(await subscriptionState(db, userId), platform.now())) {
    throw new ApiError("bad_request", "Zaten aktif bir aboneliğin var; Müşteri Portalı'ndan yönetebilirsin.");
  }
  const stripe: Stripe = stripeClient(platform, config);
  const customer: string = await customerId(db, stripe, platform, userId);
  const session: Stripe.Checkout.Session = await callStripe(platform, "checkout.sessions.create", userId, () =>
    stripe.checkout.sessions.create({
      mode: "subscription",
      customer,
      client_reference_id: userId,
      line_items: [{ price: config.stripePriceId, quantity: 1 }],
      automatic_tax: { enabled: true },
      customer_update: { address: "auto", name: "auto" },
      subscription_data: { metadata: { user_id: userId } },
      success_url: `${config.siteOrigin}/hesap?odeme=tamam`,
      cancel_url: `${config.siteOrigin}/fiyat`,
    }),
  );
  if (session.url === null) {
    throw new ApiError("upstream_unavailable", "Ödeme sayfası oluşturulamadı.");
  }
  return session.url;
}

/** Stripe Müşteri Portalı oturumu; müşteri yoksa `subscription_required`. */
export async function createPortal(db: D1Database, platform: Platform, config: Config, userId: string): Promise<string> {
  const row: { stripe_customer_id: string } | null = await db
    .prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?")
    .bind(userId)
    .first<{ stripe_customer_id: string }>();
  if (row === null) {
    throw new ApiError("subscription_required", "Henüz bir aboneliğin yok.");
  }
  const stripe: Stripe = stripeClient(platform, config);
  const session: Stripe.BillingPortal.Session = await callStripe(platform, "billingPortal.sessions.create", userId, () =>
    stripe.billingPortal.sessions.create({ customer: row.stripe_customer_id, return_url: `${config.siteOrigin}/hesap` }),
  );
  return session.url;
}

/** Abonelik olayının aboneliği; diğer olaylar kaydedilir ama durumu değiştirmez (null). Saf fonksiyondur. */
export function subscriptionFromEvent(event: Stripe.Event): Stripe.Subscription | null {
  switch (event.type) {
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
    case "customer.subscription.paused":
    case "customer.subscription.resumed":
      return event.data.object;
    default:
      return null;
  }
}

/** Aboneliğin dönem sonu: kalemlerin en geç dönem sonu (ms). Saf fonksiyondur. */
export function subscriptionPeriodEndMs(subscription: Stripe.Subscription): number {
  const ends: number[] = subscription.items.data.map((item: Stripe.SubscriptionItem): number => item.current_period_end);
  return Math.max(0, ...ends) * 1000;
}

/**
 * Stripe webhook'u: imza `constructEventAsync` ile doğrulanır (5 dakika tolerans). Olay kimliği `stripe_events`
 * tablosuna, abonelik durumu `subscriptions` tablosuna aynı toplu işlemde yazılır: aynı olay ikinci kez gelirse
 * birincil anahtar çakışır, hiçbir şey değişmez. Eski tarihli olay yeni durumu ezmez. Abonelik durumu yalnızca
 * burada yazılır.
 */
export async function handleStripeWebhook(db: D1Database, platform: Platform, config: Config, payload: string, signature: string): Promise<{ duplicate: boolean }> {
  let event: Stripe.Event;
  try {
    event = await Stripe.webhooks.constructEventAsync(
      payload,
      signature,
      config.secrets.stripeWebhook,
      300,
      Stripe.createSubtleCryptoProvider(),
      // Stripe `receivedAt`'ı milisaniye bekler (yaş = floor(receivedAt / 1000) - imza zamanı).
      platform.now().getTime(),
    );
  } catch (error: unknown) {
    log("warn", "stripe_webhook_rejected", { error: errorName(error) });
    throw new ApiError("webhook_invalid", "Webhook imzası geçersiz.");
  }
  const nowMs: number = platform.now().getTime();
  const recordEvent: D1PreparedStatement = db
    .prepare("INSERT INTO stripe_events (id, type, processed_at) VALUES (?, ?, ?)")
    .bind(event.id, event.type, nowMs);
  const statements: D1PreparedStatement[] = [recordEvent];
  const subscription: Stripe.Subscription | null = subscriptionFromEvent(event);
  if (subscription !== null) {
    const customer: string = typeof subscription.customer === "string" ? subscription.customer : subscription.customer.id;
    const owner: { user_id: string } | null = await db
      .prepare("SELECT user_id FROM stripe_customers WHERE stripe_customer_id = ?")
      .bind(customer)
      .first<{ user_id: string }>();
    if (owner === null) {
      // Bilinmeyen müşteri: olay kaydedilmez, Stripe yeniden dener; elle inceleme için uyarı.
      log("alert", "stripe_unknown_customer", { eventId: event.id, type: event.type });
      throw new ApiError("not_found", "Müşteri tanınmıyor.");
    }
    statements.push(
      db
        .prepare(
          `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, last_event_created, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(user_id) DO UPDATE SET stripe_customer_id = excluded.stripe_customer_id,
             stripe_subscription_id = excluded.stripe_subscription_id, status = excluded.status,
             current_period_end = excluded.current_period_end, last_event_created = excluded.last_event_created,
             updated_at = excluded.updated_at
           WHERE excluded.last_event_created >= subscriptions.last_event_created`,
        )
        .bind(owner.user_id, customer, subscription.id, subscription.status, subscriptionPeriodEndMs(subscription), event.created, nowMs),
    );
  }
  try {
    await db.batch(statements);
  } catch (error: unknown) {
    const seen: { id: string } | null = await db.prepare("SELECT id FROM stripe_events WHERE id = ?").bind(event.id).first<{ id: string }>();
    if (seen !== null) {
      log("info", "stripe_event_duplicate", { eventId: event.id, type: event.type });
      return { duplicate: true };
    }
    throw error;
  }
  log("info", "stripe_event_processed", { eventId: event.id, type: event.type });
  return { duplicate: false };
}

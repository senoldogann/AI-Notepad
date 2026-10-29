import Stripe from "stripe";
import { type Config, type StripeWebhookConfig, isStripeTestModeInProduction } from "./config";
import { type SubscriptionState, isTerminalSubscription, subscriptionState } from "./entitlements";
import { ApiError } from "./errors";
import { errorName, log } from "./log";
import type { Platform } from "./platform";
import { withRetries } from "./retry";

/** Stripe isteğinin zaman aşımı (SDK'nın fetch istemcisi isteğin tamamına uygular). */
const stripeTimeoutMs: number = 20_000;

/** Üretimde test modu anahtarı varsa açık uyarı yazar (ödemeler gerçek değildir). */
export function warnIfStripeTestMode(config: StripeWebhookConfig, operation: string): void {
  if (isStripeTestModeInProduction(config)) {
    log("warn", "stripe_test_mode_in_production", { operation });
  }
}

/** Stripe istemcisi (dış sistem bağlantısı): fetch tabanlı; yeniden denemeyi `withRetries` yapar. */
export function stripeClient(platform: Platform, config: StripeWebhookConfig): Stripe {
  return new Stripe(config.secrets.stripe, {
    httpClient: Stripe.createFetchHttpClient(platform.fetch),
    maxNetworkRetries: 0,
    timeout: stripeTimeoutMs,
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
async function callStripe<T>(platform: Platform, operation: string, userId: string | null, call: () => Promise<T>): Promise<T> {
  try {
    return await withRetries({ service: "stripe", attempts: 3, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableStripeError }, call);
  } catch (error: unknown) {
    const status: number | null = error instanceof Stripe.errors.StripeError ? (error.statusCode ?? null) : null;
    const requestId: string | null = error instanceof Stripe.errors.StripeError ? (error.requestId ?? null) : null;
    log("error", "stripe_failed", { operation, userId, status, requestId, error: errorName(error) });
    throw new ApiError("upstream_unavailable", "Ödeme servisine ulaşılamadı; biraz sonra yeniden dene.");
  }
}

/** Kullanıcının kayıtlı Stripe müşterisi; yoksa null. */
async function storedCustomerId(db: D1Database, userId: string): Promise<string | null> {
  const row: { stripe_customer_id: string } | null = await db
    .prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?")
    .bind(userId)
    .first<{ stripe_customer_id: string }>();
  return row === null ? null : row.stripe_customer_id;
}

/** Kullanıcının Stripe müşteri kuşağı: her `customer.deleted` ile artar (bkz. `customerCreationKey`). */
async function customerGeneration(db: D1Database, userId: string): Promise<number> {
  const row: { stripe_customer_generation: number } | null = await db
    .prepare("SELECT stripe_customer_generation FROM users WHERE id = ?")
    .bind(userId)
    .first<{ stripe_customer_generation: number }>();
  if (row === null) {
    throw new ApiError("unauthorized", "Hesap bulunamadı.");
  }
  return row.stripe_customer_generation;
}

/**
 * Müşteri oluşturmanın idempotency anahtarı: eşzamanlı ve yinelenen istekler aynı müşteriyi alır; Stripe müşterisi
 * silinince kuşak artar ve yeni anahtar yeni müşteri açar (Stripe aynı anahtara 24 saat eski yanıtı döndürür). Saf
 * fonksiyondur.
 */
export function customerCreationKey(userId: string, generation: number): string {
  return `customer-${userId}-g${generation}`;
}

/** Kullanıcının Stripe müşterisi; yoksa oluşturulur ve saklanır (sonraki ödemelerde yeniden kullanılır). */
async function customerId(db: D1Database, stripe: Stripe, platform: Platform, userId: string): Promise<string> {
  const existing: string | null = await storedCustomerId(db, userId);
  if (existing !== null) {
    return existing;
  }
  const idempotencyKey: string = customerCreationKey(userId, await customerGeneration(db, userId));
  const customer: Stripe.Customer = await callStripe(platform, "customers.create", userId, () =>
    stripe.customers.create({ metadata: { user_id: userId } }, { idempotencyKey }),
  );
  await db
    .prepare("INSERT OR IGNORE INTO stripe_customers (user_id, stripe_customer_id, created_at) VALUES (?, ?, ?)")
    .bind(userId, customer.id, platform.now().getTime())
    .run();
  const stored: string | null = await storedCustomerId(db, userId);
  if (stored === null) {
    throw new ApiError("internal_error", "Stripe müşterisi kaydedilemedi.");
  }
  return stored;
}

/** Stripe'ta yaşayan (iptal edilmemiş, süresi dolmamış) abonelik mi. Saf fonksiyondur. */
export function isLiveInStripe(subscription: Stripe.Subscription): boolean {
  return subscription.status !== "canceled" && subscription.status !== "incomplete_expired";
}

/** Stripe aboneliğinin yazılan durumu. Saf fonksiyondur. */
export function stateOf(subscription: Stripe.Subscription): SubscriptionState {
  return {
    status: subscription.status,
    currentPeriodEnd: subscriptionPeriodEndMs(subscription),
    cancelAt: subscriptionCancelAtMs(subscription),
    pastDueSince: null,
  };
}

/** Müşterinin Stripe'taki tüm abonelikleri (tek sayfa, en çok 100; fazlası alarm ve hata). */
async function customerSubscriptions(stripe: Stripe, platform: Platform, customer: string, userId: string | null): Promise<Stripe.Subscription[]> {
  const page: Stripe.ApiList<Stripe.Subscription> = await callStripe(platform, "subscriptions.list", userId, () =>
    stripe.subscriptions.list({ customer, status: "all", limit: 100 }),
  );
  if (page.has_more) {
    log("alert", "stripe_subscription_list_truncated", { userId, count: page.data.length });
    throw new ApiError("internal_error", "Abonelikler listelenemedi.");
  }
  return page.data;
}

/**
 * Müşterinin açık Checkout oturumlarını sona erdirir (ikinci sekmedeki eski ödeme sayfası ikinci aboneliği açamasın);
 * sona erdirilen sayısını döndürür.
 */
async function expireOpenCheckouts(stripe: Stripe, platform: Platform, customer: string, userId: string): Promise<number> {
  const sessions: Stripe.ApiList<Stripe.Checkout.Session> = await callStripe(platform, "checkout.sessions.list", userId, () =>
    stripe.checkout.sessions.list({ customer, status: "open", limit: 100 }),
  );
  for (const session of sessions.data) {
    await callStripe(platform, "checkout.sessions.expire", userId, () => stripe.checkout.sessions.expire(session.id));
  }
  return sessions.data.length;
}

/** Kopya abonelik iadesinin işareti (Stripe panosunda iadenin nedeni görünsün). */
export const duplicateRefundPurpose: string = "duplicate_subscription";

/**
 * Kopya aboneliği kalıcı olarak yazar (iade ve iptalden önce; tekrarı zararsız). `refundSince`: korunan aboneliğin
 * oluşturulduğu an (Stripe saniyesi); kopyanın yalnızca bundan sonra kesilen faturaları iade edilir.
 */
async function markDuplicate(db: D1Database, subscriptionId: string, userId: string, customer: string, refundSince: number, nowMs: number): Promise<void> {
  await db
    .prepare(
      `INSERT OR IGNORE INTO duplicate_subscriptions (stripe_subscription_id, user_id, stripe_customer_id, created_at, refund_since)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(subscriptionId, userId, customer, nowMs, refundSince)
    .run();
}

/** Kopya olarak yazılmış abonelik. */
interface DuplicateRecord {
  readonly userId: string;
  /** Bundan (Stripe saniyesi) önce kesilen faturaları iade edilmez; eski kayıtta null (tüm faturalar). */
  readonly refundSince: number | null;
}

/** Kopya olarak yazılmış aboneliğin kaydı; kopya değilse null. */
async function duplicateRecord(db: D1Database, subscriptionId: string): Promise<DuplicateRecord | null> {
  const row: { user_id: string; refund_since: number | null } | null = await db
    .prepare("SELECT user_id, refund_since FROM duplicate_subscriptions WHERE stripe_subscription_id = ?")
    .bind(subscriptionId)
    .first<{ user_id: string; refund_since: number | null }>();
  return row === null ? null : { userId: row.user_id, refundSince: row.refund_since };
}

/**
 * Bizim aboneliğimiz mi: Checkout'un yazdığı `metadata.user_id`'yi taşır ya da kalemlerinden biri yapılandırılmış aylık
 * fiyattır. Aynı Stripe hesabındaki başka ürünlerin abonelikleri webhook'ta iptal ya da iade edilmez. Saf fonksiyondur.
 */
export function isOurSubscription(subscription: Stripe.Subscription, priceId: string): boolean {
  const userId: string | undefined = subscription.metadata["user_id"];
  return (userId !== undefined && userId !== "") || subscription.items.data.some((item: Stripe.SubscriptionItem): boolean => item.price.id === priceId);
}

/**
 * Kopyanın iade edilecek faturaları: korunan abonelik oluşturulduktan sonra (`created >= refundSince`) kesilenler, yani
 * iki aboneliğin aynı anda ücretlendiği dönem. Kopya daha eski abonelikse onun önceki meşru ayları iade edilmez.
 * Saf fonksiyondur.
 */
export function duplicateInvoicesToRefund(invoices: readonly Stripe.Invoice[], refundSince: number): Stripe.Invoice[] {
  return invoices.filter((invoice: Stripe.Invoice): boolean => invoice.created >= refundSince);
}

/** Ödeme tamamen iade edilmiş mi (`amount_refunded >= amount`). Saf fonksiyondur. */
export function isFullyRefunded(charge: Stripe.Charge): boolean {
  return charge.amount_refunded >= charge.amount;
}

/** Faturanın aboneliği; abonelik faturası değilse null. Saf fonksiyondur. */
export function invoiceSubscriptionId(invoice: Stripe.Invoice): string | null {
  const subscription: string | Stripe.Subscription | undefined = invoice.parent?.subscription_details?.subscription;
  if (subscription === undefined) {
    return null;
  }
  return typeof subscription === "string" ? subscription : subscription.id;
}

/**
 * Fazla (kopya) aboneliğin, korunan abonelik oluşturulduktan sonra kesilmiş ödenmiş faturalarını tam iade eder
 * (`duplicateInvoicesToRefund`): aynı kişi aynı dönem için iki kez ücretlenmesin, eski meşru aylar geri ödenmesin.
 * Tekrarı güvenlidir (ödeme başına idempotency anahtarı; zaten tam iade edilmiş ödeme atlanır). İade edilen ödeme
 * sayısını döndürür.
 */
async function refundDuplicate(stripe: Stripe, platform: Platform, subscriptionId: string, userId: string, refundSince: number): Promise<number> {
  const invoices: Stripe.ApiList<Stripe.Invoice> = await callStripe(platform, "invoices.list", userId, () =>
    stripe.invoices.list({ subscription: subscriptionId, status: "paid", limit: 100 }),
  );
  let refunded: number = 0;
  for (const invoice of duplicateInvoicesToRefund(invoices.data, refundSince)) {
    if (invoice.id !== undefined) {
      refunded += await refundInvoicePayments(stripe, platform, invoice.id, subscriptionId, userId);
    }
  }
  return refunded;
}

/**
 * Ödemenin henüz tam iade edilmemiş başarılı ödemeleri (charge): ödeme niyetinin ödemeleri ya da tek ödeme. Boşsa
 * iade edilecek bir şey yoktur (Stripe zaten iade edilmiş ödemenin iadesini 24 saatlik idempotency süresinden sonra
 * reddeder; webhook yeniden denendikçe 5xx dönüp sonraki olayları tıkamasın).
 */
async function refundableCharges(stripe: Stripe, platform: Platform, target: { payment_intent: string } | { charge: string }, userId: string): Promise<Stripe.Charge[]> {
  const charges: Stripe.Charge[] =
    "payment_intent" in target
      ? (await callStripe(platform, "charges.list", userId, () => stripe.charges.list({ payment_intent: target.payment_intent, limit: 100 }))).data
      : [await callStripe(platform, "charges.retrieve", userId, () => stripe.charges.retrieve(target.charge))];
  return charges.filter((charge: Stripe.Charge): boolean => charge.paid && !isFullyRefunded(charge));
}

/**
 * Faturanın ödenmiş ödemelerini kopya iadesi olarak tam iade eder (tekrarı güvenli: zaten tam iade edilmiş ödeme
 * atlanır); iade edilen ödeme sayısı.
 */
async function refundInvoicePayments(stripe: Stripe, platform: Platform, invoice: string, subscriptionId: string, userId: string): Promise<number> {
  const payments: Stripe.ApiList<Stripe.InvoicePayment> = await callStripe(platform, "invoicePayments.list", userId, () =>
    stripe.invoicePayments.list({ invoice, status: "paid", limit: 100 }),
  );
  let refunded: number = 0;
  for (const payment of payments.data) {
    const intent: string | null = payment.payment.payment_intent === undefined
      ? null
      : typeof payment.payment.payment_intent === "string" ? payment.payment.payment_intent : payment.payment.payment_intent.id;
    const charge: string | null = payment.payment.charge === undefined
      ? null
      : typeof payment.payment.charge === "string" ? payment.payment.charge : payment.payment.charge.id;
    const target: { payment_intent: string } | { charge: string } | null = intent !== null ? { payment_intent: intent } : charge !== null ? { charge } : null;
    if (target === null) {
      log("alert", "stripe_duplicate_refund_unsupported", { userId, subscriptionId, invoiceId: invoice, paymentType: payment.payment.type });
      continue;
    }
    if ((await refundableCharges(stripe, platform, target, userId)).length === 0) {
      log("info", "stripe_duplicate_refund_already_done", { userId, subscriptionId, invoiceId: invoice });
      continue;
    }
    await callStripe(platform, "refunds.create", userId, () =>
      stripe.refunds.create(
        { ...target, reason: "duplicate", metadata: { purpose: duplicateRefundPurpose, subscription_id: subscriptionId, user_id: userId } },
        { idempotencyKey: `refund-duplicate-${subscriptionId}-${intent ?? charge}` },
      ),
    );
    refunded += 1;
  }
  return refunded;
}

/** Aboneliği Stripe'ta hemen iptal eder (tekrarı güvenli: aynı idempotency anahtarı). */
async function cancelSubscription(stripe: Stripe, platform: Platform, subscriptionId: string, userId: string | null): Promise<void> {
  await callStripe(platform, "subscriptions.cancel", userId, () =>
    stripe.subscriptions.cancel(subscriptionId, {}, { idempotencyKey: `cancel-${subscriptionId}` }),
  );
}

/**
 * Aylık abonelik için Stripe Checkout oturumu (müşteri yeniden kullanılır); ödeme adresini döndürür. Stripe Managed
 * Payments açıktır: yasal satıcı Stripe/Link'tir; vergiyi o hesaplar, toplar ve öder, adı ve fatura adresini kendisi
 * ister. Bu yüzden `automatic_tax`, `customer_update` ve `tax_id_collection` gönderilmez (Managed Payments reddeder).
 * Bitmemiş bir abonelik varsa (ek süresi geçmiş `past_due` dahil) `subscription_exists`: aynı kullanıcıda iki abonelik
 * aynı anda ücretlendirilmesin; istemci Müşteri Portalı'nı açar. Denetim önce yerel satıra, sonra Stripe'taki listeye
 * bakar (webhook'u henüz gelmemiş abonelik de yakalanır). Yeni oturumdan önce müşterinin açık Checkout oturumları sona
 * erdirilir (iki sekmede iki ödeme olmasın; yine de olursa fazlası webhook'ta iptal ve iade edilir).
 */
export async function createCheckout(db: D1Database, platform: Platform, config: Config, userId: string): Promise<string> {
  const subscriptionExists: ApiError = new ApiError(
    "subscription_exists",
    "Zaten bir aboneliğin var; yeni abonelik açılmaz. Ödeme yöntemini güncellemek ya da aboneliği yönetmek için Müşteri Portalı'nı aç.",
  );
  warnIfStripeTestMode(config, "checkout");
  const current: SubscriptionState | null = await subscriptionState(db, userId);
  if (current !== null && !isTerminalSubscription(current, platform.now())) {
    throw subscriptionExists;
  }
  const stripe: Stripe = stripeClient(platform, config);
  const customer: string = await customerId(db, stripe, platform, userId);
  const unfinished: Stripe.Subscription[] = (await customerSubscriptions(stripe, platform, customer, userId)).filter(
    (subscription: Stripe.Subscription): boolean => !isTerminalSubscription(stateOf(subscription), platform.now()),
  );
  if (unfinished.length > 0) {
    log("warn", "checkout_refused_stripe_subscription", { userId, count: unfinished.length });
    throw subscriptionExists;
  }
  // Önceki açık ödeme sayfaları kapanır: iki sekmede ödenen iki oturum iki abonelik açmasın.
  const expired: number = await expireOpenCheckouts(stripe, platform, customer, userId);
  if (expired > 0) {
    log("info", "checkout_previous_sessions_expired", { userId, count: expired });
  }
  const session: Stripe.Checkout.Session = await callStripe(platform, "checkout.sessions.create", userId, () =>
    stripe.checkout.sessions.create({
      mode: "subscription",
      customer,
      client_reference_id: userId,
      line_items: [{ price: config.stripePriceId, quantity: 1 }],
      managed_payments: { enabled: true },
      subscription_data: { metadata: { user_id: userId } },
      success_url: `${config.siteOrigin}/account?payment=done`,
      cancel_url: `${config.siteOrigin}/pricing`,
    }),
  );
  if (session.url === null) {
    throw new ApiError("upstream_unavailable", "Ödeme sayfası oluşturulamadı.");
  }
  return session.url;
}

/** Stripe Müşteri Portalı oturumu; müşteri yoksa `subscription_required`. */
export async function createPortal(db: D1Database, platform: Platform, config: Config, userId: string): Promise<string> {
  const customer: string | null = await storedCustomerId(db, userId);
  if (customer === null) {
    throw new ApiError("subscription_required", "Henüz bir aboneliğin yok.");
  }
  const stripe: Stripe = stripeClient(platform, config);
  const session: Stripe.BillingPortal.Session = await callStripe(platform, "billingPortal.sessions.create", userId, () =>
    stripe.billingPortal.sessions.create({ customer, return_url: `${config.siteOrigin}/account` }),
  );
  return session.url;
}

/**
 * Hesap silinirken Stripe tarafını kapatır: önce müşterinin açık Checkout oturumları sona erdirilir (silinen hesaba
 * yeni abonelik açılamasın), sonra bitmemiş tüm abonelikler hemen iptal edilir. Stripe müşterisi yoksa Stripe
 * çağrılmaz. Liste Stripe'tan alınır (yalnızca geçerli satır değil): webhook'u henüz gelmemiş ya da geçerli olmayan
 * abonelik de iptal edilir. Zaten iptal edilmiş abonelik atlanır; tekrar çağrı güvenlidir. İptal edilen abonelik
 * sayısını döndürür.
 */
export async function closeStripeForDeletion(db: D1Database, platform: Platform, config: Config, userId: string): Promise<number> {
  const customer: string | null = await storedCustomerId(db, userId);
  if (customer === null) {
    return 0;
  }
  const stripe: Stripe = stripeClient(platform, config);
  const expiredCheckouts: number = await expireOpenCheckouts(stripe, platform, customer, userId);
  const live: Stripe.Subscription[] = (await customerSubscriptions(stripe, platform, customer, userId)).filter(isLiveInStripe);
  for (const subscription of live) {
    await cancelSubscription(stripe, platform, subscription.id, userId);
  }
  log("info", "stripe_closed_for_deletion", { userId, expiredCheckouts, canceledSubscriptions: live.length });
  return live.length;
}

/** Abonelik olayının aboneliği; diğer olaylar null. Saf fonksiyondur. */
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
 * İptal edilmiş aboneliğin biteceği an (ms): Stripe'ın `cancel_at`'ı ya da `cancel_at_period_end` ise dönem sonu.
 * Yenilenecek abonelikte null. Saf fonksiyondur.
 */
export function subscriptionCancelAtMs(subscription: Stripe.Subscription): number | null {
  if (subscription.cancel_at !== null) {
    return subscription.cancel_at * 1000;
  }
  return subscription.cancel_at_period_end ? subscriptionPeriodEndMs(subscription) : null;
}

/** Erişim önceliği: ödenmiş (`active`, `trialing`) önce, sonra `past_due`, sonra diğer yaşayanlar. Saf fonksiyondur. */
function accessRank(subscription: Stripe.Subscription): number {
  if (subscription.status === "active" || subscription.status === "trialing") {
    return 0;
  }
  return subscription.status === "past_due" ? 1 : 2;
}

/** Müşterinin aboneliklerinden yazılacak geçerli abonelik ve iptal edilecek fazlalar. */
export interface SubscriptionChoice {
  readonly current: Stripe.Subscription | null;
  readonly duplicates: readonly Stripe.Subscription[];
}

/**
 * Kullanıcı başına tek abonelik: Stripe'ta yaşayan birden çok abonelik varsa geçerli olan erişim önceliği en yüksek,
 * eşitse en eski (`created`) olandır; diğerleri fazladır (iptal edilir: aynı kişi iki kez ücretlenmesin). Yaşayan yoksa
 * geçerli olan en son oluşturulandır (bitmiş durumu gösterilir); liste boşsa null. Saf fonksiyondur.
 */
export function chooseSubscription(subscriptions: readonly Stripe.Subscription[]): SubscriptionChoice {
  const live: Stripe.Subscription[] = subscriptions
    .filter(isLiveInStripe)
    .sort((left: Stripe.Subscription, right: Stripe.Subscription): number => accessRank(left) - accessRank(right) || left.created - right.created);
  const keeper: Stripe.Subscription | undefined = live[0];
  if (keeper !== undefined) {
    return { current: keeper, duplicates: live.slice(1) };
  }
  const newest: Stripe.Subscription | undefined = [...subscriptions].sort(
    (left: Stripe.Subscription, right: Stripe.Subscription): number => right.created - left.created,
  )[0];
  return { current: newest ?? null, duplicates: [] };
}

/** Stripe nesnesinin müşteri kimliği (genişletilmiş nesne ya da kimlik). Saf fonksiyondur. */
function customerIdOf(customer: string | Stripe.Customer | Stripe.DeletedCustomer): string {
  return typeof customer === "string" ? customer : customer.id;
}

/** Webhook'un işlediği olayın veritabanına yazılacak ifadeleri (olay kaydı hariç). */
type EventStatements = D1PreparedStatement[];

/**
 * Abonelik olayı. Olayın anlık görüntüsüne değil Stripe'taki güncel duruma güvenilir (aynı saniyedeki olaylar ters
 * sırayla gelebilir): müşterinin tüm abonelikleri listelenir ve `chooseSubscription` ile geçerli olan yazılır.
 * - Yalnızca bizim aboneliklerimiz (`isOurSubscription`) işlenir: başka ürünün (aynı Stripe hesabı) abonelik olayı
 *   loglanır ve işlenmiş sayılır; müşterinin başka ürün abonelikleri kopya sayılmaz, iade ya da iptal edilmez.
 * - Tanınmayan müşteri (ör. silinmiş hesap): abonelik Stripe'ta yaşıyorsa hemen iptal edilir ve alarm yazılır (ödeme
 *   alınıp hak verilmeyen abonelik kalmasın); olay işlenmiş sayılır.
 * - Yaşayan ikinci abonelik: fazlası (daha yeni ya da erişimi daha düşük olan) önce kalıcı olarak kopya yazılır, sonra
 *   korunan abonelik oluşturulduktan sonra kesilmiş ödenmiş faturaları tam iade edilir (`refundDuplicate`), en son
 *   iptal edilir ve alarm yazılır. İade ya da iptal başarısız olursa Stripe olayı yeniden gönderir, kopya yine bulunur;
 *   zaten iade edilmiş ödeme atlanır, kalan iş yeniden denenir. İptalden sonra geç ödenen faturası `invoice.paid` ile
 *   aynı kurala göre iade edilir (`invoicePaidDuplicateRefund`).
 * - `past_due_since`: durum `past_due` olduğunda yazılır, `past_due` sürdükçe korunur, başka duruma geçince silinir;
 *   ek süre bundan hesaplanır (`entitlements.subscriptionAccess`).
 * Yazım `last_event_created` ile sıralanır: eşzamanlı iki webhook'tan daha eski olayınki daha yeniyi ezmez.
 */
async function subscriptionEventStatements(
  db: D1Database,
  stripe: Stripe,
  platform: Platform,
  event: Stripe.Event,
  subscription: Stripe.Subscription,
  priceId: string,
): Promise<EventStatements> {
  const customer: string = customerIdOf(subscription.customer);
  const owner: { user_id: string } | null = await db
    .prepare("SELECT user_id FROM stripe_customers WHERE stripe_customer_id = ?")
    .bind(customer)
    .first<{ user_id: string }>();
  if (!isOurSubscription(subscription, priceId)) {
    log("info", "stripe_event_foreign_subscription_ignored", { eventId: event.id, type: event.type, subscriptionId: subscription.id, knownCustomer: owner !== null });
    return [];
  }
  if (owner === null) {
    const fresh: Stripe.Subscription = await callStripe(platform, "subscriptions.retrieve", null, () => stripe.subscriptions.retrieve(subscription.id));
    if (isLiveInStripe(fresh)) {
      await cancelSubscription(stripe, platform, fresh.id, null);
      log("alert", "stripe_unknown_customer_subscription_canceled", { eventId: event.id, type: event.type, subscriptionId: fresh.id, status: fresh.status });
    } else {
      log("info", "stripe_event_unknown_customer_terminal", { eventId: event.id, type: event.type });
    }
    return [];
  }
  const ours: Stripe.Subscription[] = (await customerSubscriptions(stripe, platform, customer, owner.user_id)).filter(
    (candidate: Stripe.Subscription): boolean => isOurSubscription(candidate, priceId),
  );
  const choice: SubscriptionChoice = chooseSubscription(ours);
  const current: Stripe.Subscription | null = choice.current;
  if (current === null) {
    log("alert", "stripe_subscription_missing", { eventId: event.id, userId: owner.user_id, subscriptionId: subscription.id });
    throw new ApiError("internal_error", "Müşterinin aboneliği Stripe'ta bulunamadı.");
  }
  for (const duplicate of choice.duplicates) {
    await markDuplicate(db, duplicate.id, owner.user_id, customer, current.created, platform.now().getTime());
    const refundedPayments: number = await refundDuplicate(stripe, platform, duplicate.id, owner.user_id, current.created);
    await cancelSubscription(stripe, platform, duplicate.id, owner.user_id);
    log("alert", "stripe_duplicate_subscription_canceled", {
      userId: owner.user_id,
      subscriptionId: duplicate.id,
      status: duplicate.status,
      keptSubscriptionId: current.id,
      refundedPayments,
    });
  }
  const state: SubscriptionState = stateOf(current);
  const nowMs: number = platform.now().getTime();
  return [
    db
      .prepare(
        `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, cancel_at,
           past_due_since, last_event_created, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, CASE WHEN ?4 = 'past_due' THEN ?8 END, ?7, ?8)
         ON CONFLICT(user_id) DO UPDATE SET stripe_customer_id = excluded.stripe_customer_id,
           past_due_since = CASE
             WHEN excluded.status <> 'past_due' THEN NULL
             WHEN subscriptions.status = 'past_due' AND subscriptions.stripe_subscription_id = excluded.stripe_subscription_id
               THEN COALESCE(subscriptions.past_due_since, excluded.past_due_since)
             ELSE excluded.past_due_since END,
           stripe_subscription_id = excluded.stripe_subscription_id, status = excluded.status,
           current_period_end = excluded.current_period_end, cancel_at = excluded.cancel_at,
           last_event_created = excluded.last_event_created, updated_at = excluded.updated_at
         WHERE excluded.last_event_created >= subscriptions.last_event_created`,
      )
      .bind(owner.user_id, customer, current.id, state.status, state.currentPeriodEnd, state.cancelAt, event.created, nowMs),
  ];
}

/**
 * `customer.deleted`: müşteri eşlemesi ve abonelik satırı silinir (Stripe müşteriyle birlikte abonelikleri de bitirir);
 * kullanıcının müşteri kuşağı artar ki sonraki Checkout yeni müşteri açabilsin (bkz. `customerCreationKey`).
 */
async function customerDeletedStatements(db: D1Database, event: Stripe.Event, customer: string): Promise<EventStatements> {
  const owner: { user_id: string } | null = await db
    .prepare("SELECT user_id FROM stripe_customers WHERE stripe_customer_id = ?")
    .bind(customer)
    .first<{ user_id: string }>();
  log("warn", "stripe_customer_deleted", { eventId: event.id, userId: owner?.user_id ?? null });
  const statements: EventStatements = [
    db.prepare("DELETE FROM subscriptions WHERE stripe_customer_id = ?").bind(customer),
    db.prepare("DELETE FROM stripe_customers WHERE stripe_customer_id = ?").bind(customer),
  ];
  return owner === null
    ? statements
    : [...statements, db.prepare("UPDATE users SET stripe_customer_generation = stripe_customer_generation + 1 WHERE id = ?").bind(owner.user_id)];
}

/** Müşterinin kullanıcısı; tanınmıyorsa null. */
async function customerOwner(db: D1Database, customer: string | null): Promise<string | null> {
  if (customer === null) {
    return null;
  }
  const row: { user_id: string } | null = await db
    .prepare("SELECT user_id FROM stripe_customers WHERE stripe_customer_id = ?")
    .bind(customer)
    .first<{ user_id: string }>();
  return row === null ? null : row.user_id;
}

/**
 * `charge.dispute.created`: itiraz edilen ödemenin müşterisinin bizim (`isOurSubscription`) yaşayan abonelikleri hemen
 * iptal edilir (itiraz sürerken yeni dönem ücretlenmesin) ve alarm yazılır; başka ürünlerin aboneliklerine dokunulmaz.
 * Abonelik satırı ardından gelen `customer.subscription.deleted` ile güncellenir.
 */
async function handleDispute(db: D1Database, stripe: Stripe, platform: Platform, event: Stripe.Event, dispute: Stripe.Dispute, priceId: string): Promise<void> {
  const chargeId: string = typeof dispute.charge === "string" ? dispute.charge : dispute.charge.id;
  const charge: Stripe.Charge = await callStripe(platform, "charges.retrieve", null, () => stripe.charges.retrieve(chargeId));
  const customer: string | null = charge.customer === null ? null : customerIdOf(charge.customer);
  const userId: string | null = await customerOwner(db, customer);
  const live: Stripe.Subscription[] =
    customer === null
      ? []
      : (await customerSubscriptions(stripe, platform, customer, userId)).filter(
          (subscription: Stripe.Subscription): boolean => isLiveInStripe(subscription) && isOurSubscription(subscription, priceId),
        );
  for (const subscription of live) {
    await cancelSubscription(stripe, platform, subscription.id, userId);
  }
  log("alert", "stripe_dispute_created", {
    eventId: event.id,
    disputeId: dispute.id,
    chargeId,
    userId,
    amount: dispute.amount,
    currency: dispute.currency,
    reason: dispute.reason,
    canceledSubscriptions: live.length,
  });
}

/**
 * Ödemenin ait olduğu abonelik: ödeme niyeti → fatura ödemesi → fatura → abonelik. Zincir kurulamazsa (fatura dışı
 * ödeme, eski ödeme kaydı) null.
 */
async function chargeSubscriptionId(stripe: Stripe, platform: Platform, charge: Stripe.Charge, userId: string | null): Promise<string | null> {
  const intent: string | null = charge.payment_intent === null ? null : typeof charge.payment_intent === "string" ? charge.payment_intent : charge.payment_intent.id;
  if (intent === null) {
    return null;
  }
  const payments: Stripe.ApiList<Stripe.InvoicePayment> = await callStripe(platform, "invoicePayments.list", userId, () =>
    stripe.invoicePayments.list({ payment: { type: "payment_intent", payment_intent: intent }, limit: 10 }),
  );
  const first: Stripe.InvoicePayment | undefined = payments.data[0];
  if (first === undefined) {
    return null;
  }
  const invoiceId: string = typeof first.invoice === "string" ? first.invoice : (first.invoice.id ?? "");
  if (invoiceId === "") {
    return null;
  }
  const invoice: Stripe.Invoice = await callStripe(platform, "invoices.retrieve", userId, () => stripe.invoices.retrieve(invoiceId));
  return invoiceSubscriptionId(invoice);
}

/**
 * `charge.refunded`: her iade alarm yazar. Tam iade (`refunded === true`) yalnızca o ödemenin ait olduğu aboneliği
 * bitirir (`chargeSubscriptionId`): abonelik Stripe'ta yaşıyorsa hemen iptal edilir ve satırı yalnızca abonelik kimliği
 * eşleşiyorsa aynı toplu işlemde `canceled` yazılır (erişim hemen biter; ardından gelen `customer.subscription.deleted`
 * aynı durumu yazar). Eski bir aboneliğin ödemesinin iadesi yeni aboneliğe dokunmaz. Kopya aboneliğin iadesi, aboneliği
 * bulunamayan ödeme ve kısmi iade yalnızca alarmdır.
 */
async function chargeRefundedStatements(db: D1Database, stripe: Stripe, platform: Platform, event: Stripe.Event, charge: Stripe.Charge): Promise<EventStatements> {
  const customer: string | null = charge.customer === null ? null : customerIdOf(charge.customer);
  const userId: string | null = await customerOwner(db, customer);
  const subscriptionId: string | null = charge.refunded ? await chargeSubscriptionId(stripe, platform, charge, userId) : null;
  const duplicate: boolean = subscriptionId !== null && (await duplicateRecord(db, subscriptionId)) !== null;
  const ends: boolean = subscriptionId !== null && !duplicate;
  let canceled: boolean = false;
  if (ends && subscriptionId !== null) {
    const subscription: Stripe.Subscription = await callStripe(platform, "subscriptions.retrieve", userId, () => stripe.subscriptions.retrieve(subscriptionId));
    if (isLiveInStripe(subscription)) {
      await cancelSubscription(stripe, platform, subscription.id, userId);
      canceled = true;
    }
  }
  log("alert", "stripe_charge_refunded", {
    eventId: event.id,
    chargeId: charge.id,
    userId,
    subscriptionId,
    amountRefunded: charge.amount_refunded,
    currency: charge.currency,
    fullyRefunded: charge.refunded,
    duplicateRefund: duplicate,
    canceled,
  });
  if (!ends || userId === null || subscriptionId === null) {
    return [];
  }
  const nowMs: number = platform.now().getTime();
  return [
    db
      .prepare(
        `UPDATE subscriptions SET status = 'canceled', cancel_at = ?1, past_due_since = NULL,
           last_event_created = MAX(last_event_created, ?2), updated_at = ?1
         WHERE user_id = ?3 AND stripe_subscription_id = ?4`,
      )
      .bind(nowMs, event.created, userId, subscriptionId),
  ];
}

/**
 * `invoice.paid`: fatura kopya olarak yazılmış bir aboneliğinse (iptalden sonra geç ödendi) ve korunan abonelik
 * oluşturulduktan sonra kesildiyse (`duplicateInvoicesToRefund`) ödemesi tam iade edilir (tekrarı güvenli) ve alarm
 * yazılır; kopyanın daha eski bir dönemine ait fatura iade edilmez (loglanır). Diğer faturalar yalnızca kaydedilir.
 */
async function invoicePaidDuplicateRefund(db: D1Database, stripe: Stripe, platform: Platform, event: Stripe.Event, invoice: Stripe.Invoice): Promise<void> {
  const subscriptionId: string | null = invoiceSubscriptionId(invoice);
  if (subscriptionId === null || invoice.id === undefined) {
    return;
  }
  const record: DuplicateRecord | null = await duplicateRecord(db, subscriptionId);
  if (record === null) {
    return;
  }
  if (record.refundSince !== null && duplicateInvoicesToRefund([invoice], record.refundSince).length === 0) {
    log("info", "stripe_duplicate_late_payment_kept", { eventId: event.id, userId: record.userId, subscriptionId, invoiceId: invoice.id });
    return;
  }
  const refundedPayments: number = await refundInvoicePayments(stripe, platform, invoice.id, subscriptionId, record.userId);
  log("alert", "stripe_duplicate_late_payment_refunded", { eventId: event.id, userId: record.userId, subscriptionId, invoiceId: invoice.id, refundedPayments });
}

/** Olay türüne göre Stripe yan etkileri ve veritabanı ifadeleri; tanınmayan olay yalnızca kaydedilir. */
async function eventStatements(db: D1Database, platform: Platform, config: StripeWebhookConfig, event: Stripe.Event): Promise<EventStatements> {
  const subscription: Stripe.Subscription | null = subscriptionFromEvent(event);
  if (subscription !== null) {
    return subscriptionEventStatements(db, stripeClient(platform, config), platform, event, subscription, config.stripePriceId);
  }
  switch (event.type) {
    case "customer.deleted":
      return customerDeletedStatements(db, event, event.data.object.id);
    case "charge.refunded":
      return chargeRefundedStatements(db, stripeClient(platform, config), platform, event, event.data.object);
    case "invoice.paid":
      await invoicePaidDuplicateRefund(db, stripeClient(platform, config), platform, event, event.data.object);
      return [];
    case "charge.dispute.created":
      await handleDispute(db, stripeClient(platform, config), platform, event, event.data.object, config.stripePriceId);
      return [];
    default:
      return [];
  }
}

/**
 * Stripe webhook'u (yalnızca Stripe ayarlarıyla çalışır: `StripeWebhookConfig`): imza `constructEventAsync` ile doğrulanır (5 dakika tolerans). Olayın modu (`livemode`) anahtarın
 * moduyla (`sk_live`/`rk_live` ↔ `sk_test`/`rk_test`) uyuşmazsa alarm yazılır ve `500` döner (yapılandırma hatası;
 * Stripe yeniden dener, düzeltilince olay işlenir). İşlenmiş olay Stripe çağrılmadan `duplicate` döner. Olay kimliği
 * `stripe_events` tablosuna, durum değişiklikleri aynı toplu işlemde yazılır: aynı olay eşzamanlı ikinci kez gelirse
 * birincil anahtar çakışır, hiçbir şey değişmez. İşlenen olaylar: abonelik olayları (`subscriptionEventStatements`),
 * `customer.deleted`, `charge.refunded` (alarm; tam iadede ödemenin aboneliği biter), `invoice.paid` (kopya aboneliğin geç
 * ödemesi iade edilir), `charge.dispute.created` (alarm ve abonelik iptali); diğerleri
 * yalnızca kaydedilir.
 */
export async function handleStripeWebhook(db: D1Database, platform: Platform, config: StripeWebhookConfig, payload: string, signature: string): Promise<{ duplicate: boolean }> {
  warnIfStripeTestMode(config, "webhook");
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
  if (event.livemode !== (config.stripeMode === "live")) {
    log("alert", "stripe_mode_mismatch", { eventId: event.id, type: event.type, eventLivemode: event.livemode, keyMode: config.stripeMode });
    throw new ApiError("internal_error", "Stripe anahtarının modu webhook olayıyla uyuşmuyor.");
  }
  const seen: { id: string } | null = await db.prepare("SELECT id FROM stripe_events WHERE id = ?").bind(event.id).first<{ id: string }>();
  if (seen !== null) {
    log("info", "stripe_event_duplicate", { eventId: event.id, type: event.type });
    return { duplicate: true };
  }
  const statements: EventStatements = await eventStatements(db, platform, config, event);
  const recordEvent: D1PreparedStatement = db
    .prepare("INSERT INTO stripe_events (id, type, processed_at) VALUES (?, ?, ?)")
    .bind(event.id, event.type, platform.now().getTime());
  let results: D1Result[];
  try {
    results = await db.batch([recordEvent, ...statements]);
  } catch (error: unknown) {
    const recorded: { id: string } | null = await db.prepare("SELECT id FROM stripe_events WHERE id = ?").bind(event.id).first<{ id: string }>();
    if (recorded !== null) {
      log("info", "stripe_event_duplicate", { eventId: event.id, type: event.type });
      return { duplicate: true };
    }
    throw error;
  }
  if (subscriptionFromEvent(event) !== null && statements.length > 0 && results[1]?.meta.changes !== 1) {
    // Daha yeni bir olay zaten yazılmıştı: kaydedildi, durumu değiştirmedi.
    log("info", "stripe_event_not_applied", { eventId: event.id, type: event.type });
  }
  log("info", "stripe_event_processed", { eventId: event.id, type: event.type });
  return { duplicate: false };
}

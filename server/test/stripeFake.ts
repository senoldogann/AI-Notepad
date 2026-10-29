import { env } from "cloudflare:workers";
import { randomToken } from "../src/crypto";
import type { Harness } from "./helpers";

/** Sahte Stripe'ın abonelik kalemi. */
export interface FakeSubscriptionItem {
  readonly id: string;
  readonly object: "subscription_item";
  readonly current_period_end: number;
  readonly price: { readonly id: string; readonly object: "price" };
}

/** Sahte Stripe'ın abonelik nesnesi (sunucunun okuduğu alanlar). */
export interface FakeSubscription {
  readonly id: string;
  readonly object: "subscription";
  readonly customer: string;
  readonly status: string;
  readonly created: number;
  readonly cancel_at: number | null;
  readonly cancel_at_period_end: boolean;
  readonly latest_invoice: string | null;
  readonly metadata: Readonly<Record<string, string>>;
  readonly items: { readonly object: "list"; readonly data: readonly FakeSubscriptionItem[] };
}

/** Sahte Stripe'ın faturası: aboneliği, ödenip ödenmediği ve kesildiği an (saniye). */
export interface FakeInvoice {
  readonly subscription: string;
  readonly paid: boolean;
  readonly created: number;
}

/** Sahte Stripe'ın kuponu (sunucunun okuduğu alanlar). */
export interface FakeCoupon {
  readonly id: string;
  readonly object: "coupon";
  readonly valid: boolean;
  readonly duration: string;
  readonly percent_off: number | null;
  readonly amount_off: number | null;
  readonly currency: string | null;
}

/** Sahte müşteri bakiyesi hareketi. */
export interface FakeBalanceTransaction {
  readonly id: string;
  readonly object: "customer_balance_transaction";
  readonly customer: string;
  readonly amount: number;
  readonly currency: string;
  readonly metadata: Readonly<Record<string, string>>;
}

/** Sahte ödemenin tutarı (sent). */
export const fakeChargeAmount: number = 599;

/** Sahte Stripe'ın durumu ve gelen çağrılar. */
export interface FakeStripe {
  customers: number;
  readonly checkoutForms: URLSearchParams[];
  readonly portalForms: URLSearchParams[];
  /** Abonelik kimliği → güncel nesne. */
  readonly subscriptions: Map<string, FakeSubscription>;
  /** Açık Checkout oturumu kimliği → müşteri. */
  readonly openSessions: Map<string, string>;
  readonly expiredSessions: string[];
  readonly canceled: string[];
  readonly subscriptionLists: URL[];
  /** Ödeme kimliği → müşteri. */
  readonly charges: Map<string, string>;
  /** Müşteri oluşturmanın idempotency anahtarı → müşteri (Stripe aynı anahtara aynı yanıtı döndürür). */
  readonly customerKeys: Map<string, string>;
  /** Fatura kimliği → ödenmiş ödeme niyetleri. */
  readonly invoicePayments: Map<string, string[]>;
  /** Fatura kimliği → aboneliği, ödenip ödenmediği ve kesildiği an. */
  readonly invoices: Map<string, FakeInvoice>;
  /** Oluşturulan iadeler (form) ve idempotency anahtarları. */
  readonly refundForms: URLSearchParams[];
  readonly refundKeys: string[];
  /** Tam iade edilmiş ödeme niyetleri: yeniden iade isteği 400 `charge_already_refunded` alır (idempotency süresi geçmiş gibi). */
  readonly refundedIntents: Set<string>;
  /** İade ve iptallerin sırası (`refund:<ödeme>`, `cancel:<abonelik>`). */
  readonly operations: string[];
  /** Doluysa iade isteği 500 döner (geçici Stripe hatası). */
  failRefunds: boolean;
  /** Doluysa iptal isteği 500 döner (geçici Stripe hatası). */
  failCancels: boolean;
  /** Kupon kimliği → kupon; oluşturma formları. */
  readonly coupons: Map<string, FakeCoupon>;
  readonly couponForms: URLSearchParams[];
  /** Müşteri bakiyesi hareketleri (oluşturma sırasıyla). */
  readonly balanceTransactions: FakeBalanceTransaction[];
  /** Idempotency anahtarı → hareket kimliği (Stripe 24 saat tutar; testler `clear()` ile süreyi doldurur). */
  readonly balanceKeys: Map<string, string>;
  /** İtiraz edilmiş ödeme niyetleri (`charge.disputed`). */
  readonly disputedIntents: Set<string>;
  /** Doluysa bakiye hareketi yazılır ama yanıtı 500 döner (yanıt yolda kayboldu). */
  loseBalanceResponses: boolean;
}

/** Form gövdesi. */
async function formOf(request: Request): Promise<URLSearchParams> {
  return new URLSearchParams(new TextDecoder().decode(await request.arrayBuffer()));
}

/** Stripe liste yanıtı. */
function list(url: string, data: readonly object[]): Response {
  return Response.json({ object: "list", url, has_more: false, data });
}

/**
 * `https://api.stripe.com/v1/` sahtesi: müşteri, Checkout (oluşturma, açık oturum listesi, sona erdirme), Portal,
 * abonelik (müşteriye göre liste, okuma, iptal) ve ödeme okuma. Abonelikler `subscriptions` haritasından okunur;
 * testler Stripe'ın güncel durumunu oraya yazar.
 */
export function stubStripeApi(harness: Harness): FakeStripe {
  const fake: FakeStripe = {
    customers: 0,
    checkoutForms: [],
    portalForms: [],
    subscriptions: new Map(),
    openSessions: new Map(),
    expiredSessions: [],
    canceled: [],
    subscriptionLists: [],
    charges: new Map(),
    customerKeys: new Map(),
    invoicePayments: new Map(),
    invoices: new Map(),
    refundForms: [],
    refundKeys: [],
    refundedIntents: new Set(),
    operations: [],
    failRefunds: false,
    failCancels: false,
    coupons: new Map(),
    couponForms: [],
    balanceTransactions: [],
    balanceKeys: new Map(),
    disputedIntents: new Set(),
    loseBalanceResponses: false,
  };
  harness.stub("https://api.stripe.com/v1/", async (request: Request): Promise<Response> => {
    const url: URL = new URL(request.url);
    const path: string = url.pathname;
    const method: string = request.method;
    if (method === "POST" && path === "/v1/customers") {
      const key: string = request.headers.get("idempotency-key") ?? randomToken(6);
      const cached: string | undefined = fake.customerKeys.get(key);
      if (cached !== undefined) {
        return Response.json({ id: cached, object: "customer" });
      }
      fake.customers += 1;
      const id: string = `cus_${randomToken(6)}`;
      fake.customerKeys.set(key, id);
      return Response.json({ id, object: "customer" });
    }
    if (method === "GET" && path === "/v1/invoice_payments") {
      const byInvoice: string | null = url.searchParams.get("invoice");
      const byIntent: string | null = url.searchParams.get("payment[payment_intent]");
      const paid: object[] = [...fake.invoicePayments.entries()]
        .filter(([invoice]: [string, string[]]): boolean => byInvoice === null || invoice === byInvoice)
        .flatMap(([invoice, intents]: [string, string[]]): object[] =>
          intents
            .filter((intent: string): boolean => byIntent === null || intent === byIntent)
            .map((intent: string): object => ({ id: `inpay_${intent}`, object: "invoice_payment", invoice, status: "paid", payment: { type: "payment_intent", payment_intent: intent } })),
        );
      return list("/v1/invoice_payments", paid);
    }
    const invoiceObject = (id: string, entry: FakeInvoice): object => ({
      id,
      object: "invoice",
      status: entry.paid ? "paid" : "open",
      created: entry.created,
      parent: { type: "subscription_details", subscription_details: { subscription: entry.subscription, metadata: null } },
    });
    if (method === "GET" && path === "/v1/invoices") {
      const subscription: string | null = url.searchParams.get("subscription");
      const status: string | null = url.searchParams.get("status");
      const found: object[] = [...fake.invoices.entries()]
        .filter(([, entry]: [string, FakeInvoice]): boolean => entry.subscription === subscription && (status !== "paid" || entry.paid))
        .map(([id, entry]: [string, FakeInvoice]): object => invoiceObject(id, entry));
      return list("/v1/invoices", found);
    }
    const invoicePath: RegExpExecArray | null = /^\/v1\/invoices\/([^/]+)$/.exec(path);
    if (method === "GET" && invoicePath !== null) {
      const id: string = invoicePath[1] ?? "";
      const entry: FakeInvoice | undefined = fake.invoices.get(id);
      if (entry === undefined) {
        return Response.json({ error: { type: "invalid_request_error", message: "No such invoice" } }, { status: 404 });
      }
      return Response.json(invoiceObject(id, entry));
    }
    if (method === "POST" && path === "/v1/refunds") {
      if (fake.failRefunds) {
        return Response.json({ error: { type: "api_error", message: "temporary" } }, { status: 500 });
      }
      const form: URLSearchParams = await formOf(request);
      const intent: string = form.get("payment_intent") ?? form.get("charge") ?? "";
      if (fake.refundedIntents.has(intent)) {
        return Response.json(
          { error: { type: "invalid_request_error", code: "charge_already_refunded", message: "Charge has already been refunded." } },
          { status: 400 },
        );
      }
      fake.refundedIntents.add(intent);
      fake.refundForms.push(form);
      fake.refundKeys.push(request.headers.get("idempotency-key") ?? "");
      fake.operations.push(`refund:${intent}`);
      return Response.json({ id: `re_${randomToken(6)}`, object: "refund", status: "succeeded" });
    }
    if (method === "GET" && path === "/v1/charges") {
      const intent: string = url.searchParams.get("payment_intent") ?? "";
      return list("/v1/charges", [
        {
          id: `ch_${intent}`,
          object: "charge",
          payment_intent: intent,
          paid: true,
          amount: fakeChargeAmount,
          amount_refunded: fake.refundedIntents.has(intent) ? fakeChargeAmount : 0,
          disputed: fake.disputedIntents.has(intent),
        },
      ]);
    }
    if (method === "POST" && path === "/v1/checkout/sessions") {
      const form: URLSearchParams = await formOf(request);
      fake.checkoutForms.push(form);
      const id: string = `cs_test_${fake.checkoutForms.length}`;
      fake.openSessions.set(id, form.get("customer") ?? "");
      return Response.json({ id, object: "checkout.session", url: `https://checkout.stripe.com/c/pay/${id}` });
    }
    if (method === "GET" && path === "/v1/checkout/sessions") {
      const customer: string | null = url.searchParams.get("customer");
      const open: object[] = [...fake.openSessions.entries()]
        .filter(([, owner]: [string, string]): boolean => owner === customer)
        .map(([id]: [string, string]): object => ({ id, object: "checkout.session", status: "open", url: null }));
      return list("/v1/checkout/sessions", open);
    }
    const expire: RegExpExecArray | null = /^\/v1\/checkout\/sessions\/([^/]+)\/expire$/.exec(path);
    if (method === "POST" && expire !== null) {
      const id: string = expire[1] ?? "";
      fake.openSessions.delete(id);
      fake.expiredSessions.push(id);
      return Response.json({ id, object: "checkout.session", status: "expired", url: null });
    }
    if (method === "POST" && path === "/v1/billing_portal/sessions") {
      fake.portalForms.push(await formOf(request));
      return Response.json({ id: "bps_1", object: "billing_portal.session", url: "https://billing.stripe.com/p/session/bps_1" });
    }
    if (method === "GET" && path === "/v1/subscriptions") {
      fake.subscriptionLists.push(url);
      const customer: string | null = url.searchParams.get("customer");
      return list(
        "/v1/subscriptions",
        [...fake.subscriptions.values()].filter((subscription: FakeSubscription): boolean => subscription.customer === customer),
      );
    }
    const subscriptionPath: RegExpExecArray | null = /^\/v1\/subscriptions\/([^/]+)$/.exec(path);
    if (subscriptionPath !== null) {
      const id: string = subscriptionPath[1] ?? "";
      const current: FakeSubscription | undefined = fake.subscriptions.get(id);
      if (current === undefined) {
        return Response.json({ error: { type: "invalid_request_error", message: "No such subscription" } }, { status: 404 });
      }
      if (method === "DELETE") {
        if (fake.failCancels) {
          return Response.json({ error: { type: "api_error", message: "temporary" } }, { status: 500 });
        }
        fake.canceled.push(id);
        fake.operations.push(`cancel:${id}`);
        const canceled: FakeSubscription = { ...current, status: "canceled" };
        fake.subscriptions.set(id, canceled);
        return Response.json(canceled);
      }
      return Response.json(current);
    }
    const couponPath: RegExpExecArray | null = /^\/v1\/coupons\/([^/]+)$/.exec(path);
    if (method === "GET" && couponPath !== null) {
      const coupon: FakeCoupon | undefined = fake.coupons.get(couponPath[1] ?? "");
      return coupon === undefined
        ? Response.json({ error: { type: "invalid_request_error", code: "resource_missing", message: "No such coupon" } }, { status: 404 })
        : Response.json(coupon);
    }
    if (method === "POST" && path === "/v1/coupons") {
      const form: URLSearchParams = await formOf(request);
      fake.couponForms.push(form);
      const percent: string | null = form.get("percent_off");
      const amount: string | null = form.get("amount_off");
      const coupon: FakeCoupon = {
        id: form.get("id") ?? "",
        object: "coupon",
        valid: true,
        duration: form.get("duration") ?? "",
        percent_off: percent === null ? null : Number(percent),
        amount_off: amount === null ? null : Number(amount),
        currency: form.get("currency"),
      };
      fake.coupons.set(coupon.id, coupon);
      return Response.json(coupon);
    }
    const balancePath: RegExpExecArray | null = /^\/v1\/customers\/([^/]+)\/balance_transactions$/.exec(path);
    if (balancePath !== null) {
      const customer: string = balancePath[1] ?? "";
      if (method === "GET") {
        return list(
          `/v1/customers/${customer}/balance_transactions`,
          fake.balanceTransactions.filter((transaction: FakeBalanceTransaction): boolean => transaction.customer === customer),
        );
      }
      // Idempotency: aynı anahtar (24 saat içinde) aynı hareketi döndürür.
      const key: string = request.headers.get("idempotency-key") ?? randomToken(6);
      const seen: string | undefined = fake.balanceKeys.get(key);
      const replayed: FakeBalanceTransaction | undefined = fake.balanceTransactions.find((transaction: FakeBalanceTransaction): boolean => transaction.id === seen);
      if (replayed !== undefined) {
        return fake.loseBalanceResponses
          ? Response.json({ error: { type: "api_error", message: "temporary" } }, { status: 500 })
          : Response.json(replayed);
      }
      const form: URLSearchParams = await formOf(request);
      const metadata: Record<string, string> = {};
      for (const [key, value] of form.entries()) {
        const match: RegExpExecArray | null = /^metadata\[(.+)\]$/.exec(key);
        if (match !== null && match[1] !== undefined) {
          metadata[match[1]] = value;
        }
      }
      const transaction: FakeBalanceTransaction = {
        id: `cbtxn_${randomToken(6)}`,
        object: "customer_balance_transaction",
        customer,
        amount: Number(form.get("amount")),
        currency: form.get("currency") ?? "",
        metadata,
      };
      fake.balanceTransactions.push(transaction);
      fake.balanceKeys.set(key, transaction.id);
      if (fake.loseBalanceResponses) {
        return Response.json({ error: { type: "api_error", message: "temporary" } }, { status: 500 });
      }
      return Response.json(transaction);
    }
    const chargePath: RegExpExecArray | null = /^\/v1\/charges\/([^/]+)$/.exec(path);
    if (method === "GET" && chargePath !== null) {
      const id: string = chargePath[1] ?? "";
      return Response.json({ id, object: "charge", customer: fake.charges.get(id) ?? null, paid: true, amount: fakeChargeAmount, amount_refunded: 0 });
    }
    throw new Error(`Sahte Stripe bu çağrıyı tanımıyor: ${method} ${path}`);
  });
  return fake;
}

/** Bu hizmetin yıllık aboneliği (yapılandırılmış yıllık fiyat); `created` ve dönem sonu saniyedir. */
export function fakeYearlySubscription(id: string, customer: string, status: string, created: number, periodEnd: number): FakeSubscription {
  return fakeSubscriptionWithPrice(id, customer, status, created, periodEnd, env.STRIPE_YEARLY_PRICE_ID);
}

/** Bu hizmetin aboneliği (yapılandırılmış aylık fiyat); `created` ve dönem sonu saniyedir. */
export function fakeSubscription(id: string, customer: string, status: string, created: number, periodEnd: number): FakeSubscription {
  return fakeSubscriptionWithPrice(id, customer, status, created, periodEnd, env.STRIPE_PRICE_ID);
}

/** Verilen fiyatlı, `metadata`'sız abonelik (ör. aynı Stripe hesabındaki başka ürün); `created` ve dönem sonu saniyedir. */
export function fakeSubscriptionWithPrice(id: string, customer: string, status: string, created: number, periodEnd: number, priceId: string): FakeSubscription {
  return {
    id,
    object: "subscription",
    customer,
    status,
    created,
    cancel_at: null,
    cancel_at_period_end: false,
    latest_invoice: null,
    metadata: {},
    items: { object: "list", data: [{ id: `si_${id}`, object: "subscription_item", current_period_end: periodEnd, price: { id: priceId, object: "price" } }] },
  };
}

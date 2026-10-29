import { randomToken } from "../src/crypto";
import type { Harness } from "./helpers";

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
  readonly items: { readonly object: "list"; readonly data: ReadonlyArray<{ readonly id: string; readonly object: "subscription_item"; readonly current_period_end: number }> };
}

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
  /** Fatura kimliği → aboneliği ve ödenip ödenmediği. */
  readonly invoices: Map<string, { subscription: string; paid: boolean }>;
  /** Oluşturulan iadeler (form) ve idempotency anahtarları. */
  readonly refundForms: URLSearchParams[];
  readonly refundKeys: string[];
  /** İade ve iptallerin sırası (`refund:<ödeme>`, `cancel:<abonelik>`). */
  readonly operations: string[];
  /** Doluysa iade isteği 500 döner (geçici Stripe hatası). */
  failRefunds: boolean;
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
    operations: [],
    failRefunds: false,
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
    const invoiceObject = (id: string, entry: { subscription: string; paid: boolean }): object => ({
      id,
      object: "invoice",
      status: entry.paid ? "paid" : "open",
      parent: { type: "subscription_details", subscription_details: { subscription: entry.subscription, metadata: null } },
    });
    if (method === "GET" && path === "/v1/invoices") {
      const subscription: string | null = url.searchParams.get("subscription");
      const status: string | null = url.searchParams.get("status");
      const found: object[] = [...fake.invoices.entries()]
        .filter(([, entry]: [string, { subscription: string; paid: boolean }]): boolean => entry.subscription === subscription && (status !== "paid" || entry.paid))
        .map(([id, entry]: [string, { subscription: string; paid: boolean }]): object => invoiceObject(id, entry));
      return list("/v1/invoices", found);
    }
    const invoicePath: RegExpExecArray | null = /^\/v1\/invoices\/([^/]+)$/.exec(path);
    if (method === "GET" && invoicePath !== null) {
      const id: string = invoicePath[1] ?? "";
      const entry: { subscription: string; paid: boolean } | undefined = fake.invoices.get(id);
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
      fake.refundForms.push(form);
      fake.refundKeys.push(request.headers.get("idempotency-key") ?? "");
      fake.operations.push(`refund:${form.get("payment_intent") ?? form.get("charge") ?? ""}`);
      return Response.json({ id: `re_${randomToken(6)}`, object: "refund", status: "succeeded" });
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
        fake.canceled.push(id);
        fake.operations.push(`cancel:${id}`);
        const canceled: FakeSubscription = { ...current, status: "canceled" };
        fake.subscriptions.set(id, canceled);
        return Response.json(canceled);
      }
      return Response.json(current);
    }
    const chargePath: RegExpExecArray | null = /^\/v1\/charges\/([^/]+)$/.exec(path);
    if (method === "GET" && chargePath !== null) {
      const id: string = chargePath[1] ?? "";
      return Response.json({ id, object: "charge", customer: fake.charges.get(id) ?? null });
    }
    throw new Error(`Sahte Stripe bu çağrıyı tanımıyor: ${method} ${path}`);
  });
  return fake;
}

/** Abonelik nesnesi; `created` ve dönem sonu saniyedir. */
export function fakeSubscription(id: string, customer: string, status: string, created: number, periodEnd: number): FakeSubscription {
  return {
    id,
    object: "subscription",
    customer,
    status,
    created,
    cancel_at: null,
    cancel_at_period_end: false,
    latest_invoice: null,
    items: { object: "list", data: [{ id: `si_${id}`, object: "subscription_item", current_period_end: periodEnd }] },
  };
}

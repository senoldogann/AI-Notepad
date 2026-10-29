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
  /** Oluşturulan iadeler (form) ve idempotency anahtarları. */
  readonly refundForms: URLSearchParams[];
  readonly refundKeys: string[];
  /** Ödeme kimliği → iadelerinin üst verisindeki amaç (`purpose`). */
  readonly chargeRefunds: Map<string, Array<string | null>>;
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
    refundForms: [],
    refundKeys: [],
    chargeRefunds: new Map(),
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
      const invoice: string = url.searchParams.get("invoice") ?? "";
      const paid: object[] = (fake.invoicePayments.get(invoice) ?? []).map((intent: string): object => ({
        id: `inpay_${intent}`,
        object: "invoice_payment",
        invoice,
        status: "paid",
        payment: { type: "payment_intent", payment_intent: intent },
      }));
      return list("/v1/invoice_payments", paid);
    }
    if (method === "POST" && path === "/v1/refunds") {
      fake.refundForms.push(await formOf(request));
      fake.refundKeys.push(request.headers.get("idempotency-key") ?? "");
      return Response.json({ id: `re_${randomToken(6)}`, object: "refund", status: "succeeded" });
    }
    if (method === "GET" && path === "/v1/refunds") {
      const charge: string = url.searchParams.get("charge") ?? "";
      const refunds: object[] = (fake.chargeRefunds.get(charge) ?? []).map((purpose: string | null, index: number): object => ({
        id: `re_${charge}_${index}`,
        object: "refund",
        charge,
        metadata: purpose === null ? {} : { purpose },
      }));
      return list("/v1/refunds", refunds);
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

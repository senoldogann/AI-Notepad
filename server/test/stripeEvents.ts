import { env } from "cloudflare:workers";
import Stripe from "stripe";
import { type Harness, req } from "./helpers";
import type { FakeStripe, FakeSubscription } from "./stripeFake";

/** İmzalanacak Stripe olayı gövdesi (test modu). */
export function eventOf(id: string, type: string, created: number, object: object): string {
  return JSON.stringify({
    id,
    object: "event",
    type,
    created,
    api_version: "2026-09-30.endive",
    livemode: false,
    pending_webhooks: 1,
    request: { id: null, idempotency_key: null },
    data: { object },
  });
}

/** Olayı testlerin webhook sırrıyla imzalayıp gönderir. */
export async function postEvent(harness: Harness, payload: string): Promise<Response> {
  const signature: string = await Stripe.webhooks.generateTestHeaderStringAsync({
    payload,
    secret: env.STRIPE_WEBHOOK_SECRET,
    timestamp: Math.floor(harness.clock.nowMs / 1000),
    cryptoProvider: Stripe.createSubtleCryptoProvider(),
  });
  return harness.call(req("POST", "/v1/billing/webhook", { body: payload, headers: { "stripe-signature": signature, "content-type": "application/json" } }));
}

/** Aboneliğin güncel durumunu sahte Stripe'a yazıp abonelik olayını gönderir (Stripe olayı durum değiştikten sonra yollar). */
export async function sendSubscription(harness: Harness, stripe: FakeStripe, eventId: string, type: string, created: number, subscription: FakeSubscription): Promise<Response> {
  stripe.subscriptions.set(subscription.id, subscription);
  return postEvent(harness, eventOf(eventId, type, created, subscription));
}

/** Ödenmiş faturanın alanları. */
export interface PaidInvoiceFields {
  readonly eventId: string;
  readonly invoiceId: string;
  readonly customer: string;
  readonly subscriptionId: string;
  /** Ödenen tutar (sent); davetle aylık aboneliğin ilk faturası 0. */
  readonly amountPaid: number;
  /** Aboneliğin metadata'sındaki davet kodu; yoksa null. */
  readonly referralCode: string | null;
  readonly created: number;
}

/** Faturanın vergi oranı (tutarların vergi dahil fiyattaki payı; testlerde %24 KDV). */
const testTaxRate: number = 0.24;

/**
 * Ödenmiş faturanın tutar alanları (Stripe'ın gönderdiği biçimde): vergi dahil fiyat, vergisi ve ödenme anı. İndirim
 * yoksa `discount` 0.
 */
export function paidInvoiceAmounts(amountPaid: number, discount: number, created: number, currency: string): object {
  const tax: number = Math.round(amountPaid - amountPaid / (1 + testTaxRate));
  return {
    currency,
    amount_paid: amountPaid,
    amount_due: amountPaid,
    subtotal: amountPaid + discount,
    total: amountPaid,
    total_excluding_tax: amountPaid - tax,
    total_taxes: amountPaid === 0 ? [] : [{ amount: tax, tax_behavior: "inclusive", taxability_reason: "standard_rated", taxable_amount: amountPaid - tax, type: "tax_rate_details", tax_rate_details: null }],
    total_discount_amounts: discount === 0 ? [] : [{ amount: discount, discount: "di_test" }],
    status_transitions: { paid_at: created, finalized_at: created, marked_uncollectible_at: null, voided_at: null },
    billing_reason: "subscription_cycle",
  };
}

/** `invoice.paid` olayı (abonelik metadata'sının faturadaki kopyasıyla). */
export function invoicePaidEvent(fields: PaidInvoiceFields): string {
  return eventOf(fields.eventId, "invoice.paid", fields.created, {
    ...paidInvoiceAmounts(fields.amountPaid, 0, fields.created, "usd"),
    id: fields.invoiceId,
    object: "invoice",
    customer: fields.customer,
    status: "paid",
    created: fields.created,
    parent: {
      type: "subscription_details",
      subscription_details: {
        subscription: fields.subscriptionId,
        metadata: fields.referralCode === null ? {} : { referral_code: fields.referralCode },
      },
    },
  });
}

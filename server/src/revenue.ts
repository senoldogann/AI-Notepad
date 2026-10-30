import type Stripe from "stripe";
import { activeAccessSql } from "./admin";
import { freeInviteMonthSql } from "./referrals";
import { dayKey } from "./usage";

/**
 * Gerçek gelir (`revenue_invoices`, `revenue_refunds`; göç 0042): Stripe webhook'u ödenmiş abonelik faturalarını ve
 * iadelerini yazar, yönetim paneli ve günlük anlık görüntü bunlardan gerçek MRR, ARPU, LTV ve iadeleri hesaplar.
 * Tutarlar faturanın para biriminin en küçük biriminde (sent) ve para birimine göre ayrıdır (Link kasası yerel para
 * birimiyle de satabilir). Kart ya da ödeme bilgisi yazılmaz; hesap silinince `user_id` kaldırılır.
 */

/** Ödenmiş faturanın gelir satırı. */
export interface InvoiceRevenue {
  readonly invoiceId: string;
  readonly subscriptionId: string;
  readonly paidAtMs: number;
  readonly currency: string;
  /** Tahsil edilen (vergi dahil; müşteri bakiyesinden düşülen kısım hariç). */
  readonly amountPaid: number;
  /** Vergisiz toplam (indirimden sonra, müşteri bakiyesinden önce). */
  readonly totalExcludingTax: number;
  readonly discount: number;
  readonly tax: number;
  readonly billingReason: string | null;
}

/**
 * Faturanın gelir satırı. Ödeme anı `status_transitions.paid_at`; Stripe onu boş bıraktıysa olayın anı (saniye).
 * Vergisiz toplam `total_excluding_tax`; Stripe onu boş bıraktıysa tanımı gereği `total` − vergiler. Saf fonksiyondur.
 */
export function invoiceRevenueOf(invoice: Stripe.Invoice, invoiceId: string, subscriptionId: string, eventCreatedSeconds: number): InvoiceRevenue {
  const tax: number = (invoice.total_taxes ?? []).reduce((sum: number, item: Stripe.Invoice.TotalTax): number => sum + item.amount, 0);
  const discount: number = (invoice.total_discount_amounts ?? []).reduce((sum: number, item: Stripe.Invoice.TotalDiscountAmount): number => sum + item.amount, 0);
  return {
    invoiceId,
    subscriptionId,
    paidAtMs: (invoice.status_transitions.paid_at ?? eventCreatedSeconds) * 1000,
    currency: invoice.currency.toLowerCase(),
    amountPaid: invoice.amount_paid,
    totalExcludingTax: invoice.total_excluding_tax ?? invoice.total - tax,
    discount,
    tax,
    billingReason: invoice.billing_reason,
  };
}

/**
 * `invoice.paid` gelir ifadeleri: fatura satırı (aynı fatura ikinci kez yazılmaz) ve tutarı 0'dan büyükse hesabın ilk
 * ücretli ödeme anı (`subscriptions.first_paid_at`, yalnızca boşsa; abonelik satırı henüz yoksa abonelik olayı onu
 * buradan doldurur, bkz. `firstPaidAtSql`).
 */
export function revenueInvoiceStatements(db: D1Database, userId: string, revenue: InvoiceRevenue): D1PreparedStatement[] {
  const insert: D1PreparedStatement = db
    .prepare(
      `INSERT INTO revenue_invoices (invoice_id, user_id, subscription_id, day, paid_at, currency, amount_paid, total_excluding_tax, discount, tax, billing_reason)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(invoice_id) DO NOTHING`,
    )
    .bind(
      revenue.invoiceId,
      userId,
      revenue.subscriptionId,
      dayKey(new Date(revenue.paidAtMs)),
      revenue.paidAtMs,
      revenue.currency,
      revenue.amountPaid,
      revenue.totalExcludingTax,
      revenue.discount,
      revenue.tax,
      revenue.billingReason,
    );
  if (revenue.amountPaid <= 0) {
    return [insert];
  }
  return [
    insert,
    db.prepare("UPDATE subscriptions SET first_paid_at = ? WHERE user_id = ? AND first_paid_at IS NULL").bind(revenue.paidAtMs, userId),
  ];
}

/**
 * Hesabın ilk ücretli faturasının anı (SQL ifadesi; abonelik satırı yazılırken). Bağ: hesap kimliğinin SQL ifadesi.
 */
export function firstPaidAtSql(userRef: string): string {
  return `(SELECT MIN(paid_at) FROM revenue_invoices WHERE user_id = ${userRef} AND amount_paid > 0)`;
}

/**
 * `charge.refunded` gelir ifadesi: ödemenin faturası `revenue_invoices`'ta ise (bizim abonelik faturamız) birikimli iade
 * tutarı yazılır; tutar büyüdüyse gün ve an güncellenir (yinelenen ya da sırasız olay tutarı küçültmez).
 */
export function revenueRefundStatement(db: D1Database, charge: Stripe.Charge, invoiceId: string, refundedAtMs: number): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO revenue_refunds (charge_id, invoice_id, day, refunded_at, currency, amount_refunded)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6 WHERE EXISTS (SELECT 1 FROM revenue_invoices WHERE invoice_id = ?2)
       ON CONFLICT(charge_id) DO UPDATE SET
         day = CASE WHEN excluded.amount_refunded > revenue_refunds.amount_refunded THEN excluded.day ELSE revenue_refunds.day END,
         refunded_at = CASE WHEN excluded.amount_refunded > revenue_refunds.amount_refunded THEN excluded.refunded_at ELSE revenue_refunds.refunded_at END,
         amount_refunded = MAX(revenue_refunds.amount_refunded, excluded.amount_refunded)`,
    )
    .bind(charge.id, invoiceId, dayKey(new Date(refundedAtMs)), refundedAtMs, charge.currency.toLowerCase(), charge.amount_refunded);
}

/** Hesap silinirken gelir satırlarının hesap bağı kaldırılır (satırlar muhasebe için kalır). */
export function revenueDeletionStatement(db: D1Database, userId: string): D1PreparedStatement {
  return db.prepare("UPDATE revenue_invoices SET user_id = NULL WHERE user_id = ?").bind(userId);
}

/** Para birimi başına faturalanan MRR. */
export interface CurrencyMrr {
  readonly currency: string;
  readonly mrrCents: number;
  readonly payingSubscriptions: number;
}

/**
 * `nowMs` anında yenilenecek ödenmiş aboneliklerin (liste MRR'ıyla aynı küme: faturalı, erişimi süren, iptal edilmemiş,
 * planı bilinen, davetin ücretsiz ayında olmayan) faturalanan MRR'ı: her aboneliğin tutarı 0'dan büyük son faturasının
 * vergisiz toplamı, yıllıkta /12; para birimine göre. Ücretli faturası henüz kaydedilmemiş abonelik (bu tablodan önceki
 * aboneler) sayılmaz. Yuvarlama sent'e.
 */
export async function invoicedMrrByCurrency(db: D1Database, nowMs: number): Promise<CurrencyMrr[]> {
  const rows = await db
    .prepare(
      `SELECT i.currency AS currency,
         CAST(ROUND(SUM(CASE WHEN s.plan = 'yearly' THEN i.total_excluding_tax / 12.0 ELSE i.total_excluding_tax END)) AS INTEGER) AS mrr_cents,
         COUNT(*) AS paying
       FROM subscriptions s
       JOIN revenue_invoices i ON i.invoice_id = (
         SELECT l.invoice_id FROM revenue_invoices l
         WHERE l.subscription_id = s.stripe_subscription_id AND l.amount_paid > 0 AND l.paid_at <= ?1
         ORDER BY l.paid_at DESC LIMIT 1)
       WHERE s.complimentary = 0 AND ${activeAccessSql} AND s.cancel_at IS NULL AND s.plan IS NOT NULL AND NOT ${freeInviteMonthSql}
       GROUP BY i.currency ORDER BY mrr_cents DESC, i.currency`,
    )
    .bind(nowMs)
    .all<{ currency: string; mrr_cents: number; paying: number }>();
  return rows.results.map((row): CurrencyMrr => ({ currency: row.currency, mrrCents: row.mrr_cents, payingSubscriptions: row.paying }));
}

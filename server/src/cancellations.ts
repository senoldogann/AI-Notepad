import type Stripe from "stripe";

/**
 * Abonelik iptallerinin nedeni (`subscription_cancellations`; yönetim paneli "Neden iptal ediyorlar"). Stripe'ın abonelik
 * olaylarındaki `cancellation_details` yazılır: `reason` (Stripe'ın nedeni), `feedback` (Müşteri Portalı'ndaki iptal
 * formunun sabit seçeneği) ve `comment` (müşterinin serbest metni). Satır yalnızca hesap kimliğine bağlıdır; e-posta ya
 * da ad tutulmaz. Hesap silinince ve 180 gün sonra silinir.
 */

/** Saklanan yorumun en çok uzunluğu (karakter); fazlası kesilir. */
export const cancellationCommentMaxLength: number = 1000;

/** Sabit seçenek alanlarının (`reason`, `feedback`) en çok uzunluğu; Stripe'ın değerleri kısadır, fazlası kesilir. */
const cancellationCodeMaxLength: number = 64;

/** Olaydan okunan iptal nedeni. */
export interface CancellationDetails {
  readonly reason: string | null;
  readonly feedback: string | null;
  readonly comment: string | null;
}

/** Boş metni null'a, uzun metni sınıra çevirir. Saf fonksiyondur. */
function trimmedOrNull(value: string | null | undefined, maxLength: number): string | null {
  const trimmed: string = (value ?? "").trim();
  return trimmed === "" ? null : trimmed.slice(0, maxLength);
}

/**
 * Aboneliğin iptal nedeni: abonelik iptal edildiyse (`canceled`) ya da iptali planlandıysa (`cancel_at`,
 * `cancel_at_period_end`) ve Stripe en az bir alan verdiyse dolu; yoksa null (yazılacak bir şey yok). Saf fonksiyondur.
 */
export function cancellationDetailsOf(subscription: Stripe.Subscription): CancellationDetails | null {
  const canceling: boolean = subscription.status === "canceled" || subscription.cancel_at !== null || subscription.cancel_at_period_end;
  // Eski API sürümlerinde ve testlerin sahte nesnelerinde alan hiç olmayabilir.
  const details: Stripe.Subscription.CancellationDetails | null = subscription.cancellation_details ?? null;
  if (!canceling || details === null) {
    return null;
  }
  const result: CancellationDetails = {
    reason: trimmedOrNull(details.reason, cancellationCodeMaxLength),
    feedback: trimmedOrNull(details.feedback, cancellationCodeMaxLength),
    comment: trimmedOrNull(details.comment, cancellationCommentMaxLength),
  };
  return result.reason === null && result.feedback === null && result.comment === null ? null : result;
}

/** Abonelik yeniden yenilenecek durumda mı (iptal geri alındı): yaşıyor ve iptali planlı değil. Saf fonksiyondur. */
export function isRenewing(subscription: Stripe.Subscription): boolean {
  return subscription.status !== "canceled" && subscription.cancel_at === null && !subscription.cancel_at_period_end;
}

/**
 * Abonelik olayının iptal nedeni ifadesi (`customer.subscription.updated` ve `.deleted`; diğer olaylarda boş): nedeni
 * olan iptal yazılır (alan alan; boş gelen alan eskisini silmez), iptali geri alınan aboneliğin satırı silinir.
 * Ters sırada gelen eski olay yeniyi ezmez (`event_created`). Saf fonksiyondur (ifadeyi hazırlar, çalıştırmaz).
 */
export function cancellationStatements(
  db: D1Database,
  event: Stripe.Event,
  subscription: Stripe.Subscription,
  userId: string,
  nowMs: number,
): D1PreparedStatement[] {
  if (event.type !== "customer.subscription.updated" && event.type !== "customer.subscription.deleted") {
    return [];
  }
  if (isRenewing(subscription)) {
    return [
      db
        .prepare("DELETE FROM subscription_cancellations WHERE stripe_subscription_id = ? AND event_created <= ?")
        .bind(subscription.id, event.created),
    ];
  }
  const details: CancellationDetails | null = cancellationDetailsOf(subscription);
  if (details === null) {
    return [];
  }
  return [
    db
      .prepare(
        `INSERT INTO subscription_cancellations (stripe_subscription_id, user_id, created_at, event_created, reason, feedback, comment)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(stripe_subscription_id) DO UPDATE SET event_created = excluded.event_created,
           reason = COALESCE(excluded.reason, subscription_cancellations.reason),
           feedback = COALESCE(excluded.feedback, subscription_cancellations.feedback),
           comment = COALESCE(excluded.comment, subscription_cancellations.comment)
         WHERE excluded.event_created >= subscription_cancellations.event_created`,
      )
      .bind(subscription.id, userId, nowMs, event.created, details.reason, details.feedback, details.comment),
  ];
}

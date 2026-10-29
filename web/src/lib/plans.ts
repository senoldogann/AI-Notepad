// Abonelik planları (sunucunun `POST /v1/billing/checkout` gövdesindeki `plan`): aylık 5,99 $ ya da yıllık 49 $, vergiler
// dahil. Fiyat metinleri copy.ts'tedir; burada yalnızca planların adları ve sitenin varsayılan seçimi vardır.

/** Abonelik planı. */
export type BillingPlan = "monthly" | "yearly";

/** Planların gösterim sırası (fiyat sayfası ve hesap sayfasındaki seçim). */
export const billingPlans: readonly BillingPlan[] = ["monthly", "yearly"];

/** Abone olurken önceden seçili plan (sahibin kararı: yıllık). */
export const recommendedPlan: BillingPlan = "yearly";

/** Metin geçerli bir plan adıysa planı, değilse null döndürür (adres sorgusu ve depolama okunurken). Saf fonksiyondur. */
export function billingPlanOf(value: string | null): BillingPlan | null {
  return value === "monthly" || value === "yearly" ? value : null;
}

/** Davet kodunun biçimi (sunucu büyük harfe çevirir, boşluk ve tireyi atar; burada yalnızca kaba denetim). */
const inviteCodePattern: RegExp = /^[A-Z0-9]{6,16}$/;

/**
 * Kullanıcının yazdığı ya da adresten gelen davet kodunu sunucunun beklediği biçime yaklaştırır: büyük harf, boşluk ve
 * tire yok. Biçimi tutmayan metin null (sunucuya hiç gönderilmez). Saf fonksiyondur.
 */
export function normalizedInviteCode(value: string): string | null {
  const code: string = value.toUpperCase().replace(/[\s-]+/g, "");
  return inviteCodePattern.test(code) ? code : null;
}

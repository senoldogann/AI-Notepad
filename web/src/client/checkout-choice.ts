// Abone olmadan önceki seçimlerin tarayıcıdaki kaydı: davet sayfasından ya da davet bağlantısından gelen kod
// (localStorage: kullanıcı önce uygulamayı indirip sonra abone olabilir) ve fiyat sayfasında seçilen plan
// (sessionStorage: giriş yönlendirmesi aynı sekmede kalır). Depolama kapalıysa uyarı yazılır, seçim yalnızca o sayfada
// kalır (temanın davranışıyla aynı).
import { type BillingPlan, billingPlanOf, normalizedInviteCode } from "../lib/plans";

/** Davet kodunun anahtarı (localStorage). */
const inviteKey: string = "gistsmith.invite";
/** Seçilen planın anahtarı (sessionStorage). */
const planKey: string = "gistsmith.plan";

/** Depolama işlemini yapar; tarayıcı depolamayı engellediyse uyarı yazar ve null döndürür. */
function withStorage<T>(operation: string, action: () => T): T | null {
  try {
    return action();
  } catch (error: unknown) {
    console.warn("checkout_choice_storage_unavailable", { operation, error: error instanceof Error ? error.message : String(error) });
    return null;
  }
}

/** Kayıtlı davet kodu; yoksa ya da biçimsizse null. */
export function storedInviteCode(): string | null {
  const value: string | null = withStorage("read_invite", (): string | null => window.localStorage.getItem(inviteKey));
  return value === null ? null : normalizedInviteCode(value);
}

/** Davet kodunu kaydeder. */
export function storeInviteCode(code: string): void {
  withStorage("write_invite", (): void => window.localStorage.setItem(inviteKey, code));
}

/** Kayıtlı davet kodunu siler (abone olunca ya da kullanıcı kaldırınca). */
export function forgetInviteCode(): void {
  withStorage("remove_invite", (): void => window.localStorage.removeItem(inviteKey));
}

/** Bu sekmede seçilen plan; yoksa null. */
export function storedPlan(): BillingPlan | null {
  return billingPlanOf(withStorage("read_plan", (): string | null => window.sessionStorage.getItem(planKey)));
}

/** Seçilen planı bu sekme için kaydeder. */
export function storePlan(plan: BillingPlan): void {
  withStorage("write_plan", (): void => window.sessionStorage.setItem(planKey, plan));
}

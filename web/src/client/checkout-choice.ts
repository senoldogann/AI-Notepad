// Abone olmadan önceki seçimlerin tarayıcıdaki kaydı: davet sayfasından ya da davet bağlantısından gelen kod ve fiyat
// sayfasında seçilen plan (localStorage: kullanıcı önce uygulamayı indirip sonra abone olabilir, giriş başka bir sekmede
// ya da daha sonraki bir ziyarette bitebilir; seçim girişten sonra kaybolmaz) ve "ödemeye devam et" niyeti
// (sessionStorage: yalnızca seçimin yapıldığı sekmede, giriş yönlendirmesi aynı sekmede kalır; başka sekmede hesabı
// açan kullanıcı kendiliğinden ödeme sayfasına gitmez). Depolama kapalıysa uyarı yazılır, seçim yalnızca o sayfada
// kalır (temanın davranışıyla aynı).
import { type BillingPlan, billingPlanOf, normalizedInviteCode } from "../lib/plans";

/** Davet kodunun anahtarı (localStorage). */
const inviteKey: string = "gistsmith.invite";
/** Seçilen planın anahtarı (localStorage). */
const planKey: string = "gistsmith.plan";
/** "Seçilen planla ödemeye devam et" niyetinin anahtarı (sessionStorage). */
const checkoutKey: string = "gistsmith.checkout";

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

/** Seçilen plan; yoksa null. Girişten ve sekme kapanmasından sonra da durur. */
export function storedPlan(): BillingPlan | null {
  return billingPlanOf(withStorage("read_plan", (): string | null => window.localStorage.getItem(planKey)));
}

/** Seçilen planı kaydeder. */
export function storePlan(plan: BillingPlan): void {
  withStorage("write_plan", (): void => window.localStorage.setItem(planKey, plan));
}

/** Kayıtlı planı siler (abonelik başlayınca seçim anlamını yitirir). */
export function forgetPlan(): void {
  withStorage("remove_plan", (): void => window.localStorage.removeItem(planKey));
}

/** Bu sekmede ödemeye devam etme niyeti var mı. */
export function checkoutIntended(): boolean {
  return withStorage("read_checkout", (): boolean => window.sessionStorage.getItem(checkoutKey) === "1") === true;
}

/** Ödemeye devam etme niyetini bu sekme için kaydeder. */
export function storeCheckoutIntent(): void {
  withStorage("write_checkout", (): void => window.sessionStorage.setItem(checkoutKey, "1"));
}

/** Niyeti siler (kullanıldı, abonelik var ya da kullanıcı vazgeçti). */
export function forgetCheckoutIntent(): void {
  withStorage("remove_checkout", (): void => window.sessionStorage.removeItem(checkoutKey));
}

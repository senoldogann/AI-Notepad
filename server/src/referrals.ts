import type { Config, SubscriptionPlan } from "./config";
import { randomId } from "./crypto";
import { type SubscriptionState, isTerminalSubscription, subscriptionAccess, subscriptionState } from "./entitlements";
import { ApiError } from "./errors";
import { log } from "./log";
import type { IdentityProvider } from "./auth/users";
import { trialIdentityHash } from "./trialLedger";

/**
 * Davet programı ("bir ay ver, bir ay al"):
 * - Abonelik erişimi olan her hesap kişisel bir davet kodu alır (`GET /v1/referral`; ilk istekte üretilir).
 * - Hiç abone olmamış yeni hesap kodla abone olursa: aylıkta ilk ay ücretsiz (tek seferlik %100 kupon), yıllıkta ilk
 *   yıla tek seferlik bir aylık fiyat (5,99 $) indirim. Kod Checkout'tan önce sunucuda doğrulanır (`requireReferral`),
 *   indirim Checkout oturumuna sunucu tarafından eklenir (`billing.ts`); kullanıcı kupon yazamaz.
 * - Davet edilenin ilk gerçek (sıfırdan büyük) ödemesi `invoice.paid` ile `qualified` olur; `referralHoldMs` boyunca
 *   iade ya da itiraz gelmezse günlük Cron davet edene bir aylık fiyat kadar Stripe müşteri bakiyesi alacağı yazar
 *   (`referralRewards.ts`): sonraki faturasından düşülür.
 * - Kötüye kullanım sınırları: kendi kodu ve aynı Mac'i (App Attest cihazı) paylaşan hesaplar reddedilir
 *   (`referral_self`); daha önce abonelik açmış ya da aynı giriş kimliğiyle daha önce davetle abone olmuş hesap kod
 *   kullanamaz (`referral_not_eligible`; kimlik özeti hesap silinince de kalır); davet eden son 365 günde en çok
 *   `referralRewardsPerYear` ödül alır; kodlar rastgeledir ve doğrulama kullanıcı başına hız sınırlıdır.
 */

/** Kod alfabesi: karışan karakterler (0, 1, I, L, O) yok; 31 harf. */
export const referralCodeAlphabet: string = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";

/** Kod uzunluğu: 31^8 ≈ 8,5 × 10^11 olası kod (tahmin edilemez; doğrulama hız sınırlıdır). */
export const referralCodeLength: number = 8;

/** Davet edilenin ilk gerçek ödemesinden ödüle dek beklenen süre: bu sürede gelen iade ya da itiraz ödülü düşürür. */
export const referralHoldDays: number = 30;
export const referralHoldMs: number = referralHoldDays * 86_400_000;

/** Davet edenin son 365 günde alabileceği en çok ödül. */
export const referralRewardsPerYear: number = 12;

/** Ödül sınırının geriye bakış süresi. */
export const referralRewardWindowMs: number = 365 * 86_400_000;

/** Davet satırının durumu (bkz. `migrations/0038_referrals.sql`). */
export type ReferralStatus = "checkout" | "joined" | "qualified" | "granted" | "capped" | "void";

/** Ödülün düşme nedeni (`referrer_complimentary`: davet edenin ücretsiz erişimi var, bkz. `complimentary.ts`). */
export type ReferralVoidReason = "refunded" | "disputed" | "self_referral" | "referrer_deleted" | "referrer_no_customer" | "referrer_complimentary";

/** Davet indirimi: aylıkta ilk ay ücretsiz, yıllıkta ilk yıla bir aylık fiyat kadar indirim. */
export type ReferralDiscount = "first_month_free" | "first_year_month_off";

/** Planın davet indirimi. Saf fonksiyondur. */
export function referralDiscountOf(plan: SubscriptionPlan): ReferralDiscount {
  return plan === "monthly" ? "first_month_free" : "first_year_month_off";
}

/** Fiyatın sent karşılığı (ör. 5.99 → 599). Saf fonksiyondur. */
export function usdCents(usd: number): number {
  return Math.round(usd * 100);
}

/** Girilen kodu karşılaştırılabilir biçime çevirir: boşluklar ve tireler atılır, büyük harfe çevrilir. Saf fonksiyondur. */
export function normalizeReferralCode(raw: string): string {
  return raw.replace(/[\s-]/g, "").toUpperCase();
}

/** Kod biçimi geçerli mi (uzunluk ve alfabe). Saf fonksiyondur. */
export function isReferralCodeShape(code: string): boolean {
  return code.length === referralCodeLength && [...code].every((char: string): boolean => referralCodeAlphabet.includes(char));
}

/**
 * Rastgele baytlardan kod: reddetme örneklemesi (31 × 8 = 248'den küçük baytlar kullanılır; dağılım düzgündür). Yeterli
 * kabul edilen bayt yoksa null. Saf fonksiyondur.
 */
export function referralCodeFromBytes(bytes: Uint8Array): string | null {
  const limit: number = referralCodeAlphabet.length * Math.floor(256 / referralCodeAlphabet.length);
  const chars: string[] = [];
  for (const byte of bytes) {
    if (byte < limit) {
      chars.push(referralCodeAlphabet[byte % referralCodeAlphabet.length] ?? "");
    }
    if (chars.length === referralCodeLength) {
      return chars.join("");
    }
  }
  return null;
}

/** Kriptografik rastgele yeni kod. */
export function newReferralCode(): string {
  for (;;) {
    const code: string | null = referralCodeFromBytes(crypto.getRandomValues(new Uint8Array(32)));
    if (code !== null) {
      return code;
    }
  }
}

/** Davet bağlantısı (sitedeki `/invite` sayfası kodu gösterir ve Checkout'a taşır). Saf fonksiyondur. */
export function inviteUrl(siteOrigin: string, code: string): string {
  return `${siteOrigin}/invite?code=${encodeURIComponent(code)}`;
}

/** `GET /v1/referral` yanıtı. */
export interface ReferralSummary {
  readonly enabled: boolean;
  /** Program açık ve hesabın abonelik erişimi varsa kod ve bağlantı; değilse null. */
  readonly code: string | null;
  readonly inviteUrl: string | null;
  /** Kodla abone olan (ilk faturası ödenmiş) arkadaş sayısı. */
  readonly joined: number;
  /** Verilen ödül (bir aylık ücret kadar alacak) sayısı. */
  readonly rewarded: number;
  /** Abone olmuş, ödülü henüz verilmemiş (ilk gerçek ödeme ya da bekleme süresi bekleniyor). */
  readonly pending: number;
  /**
   * Bekleyen ödüllerin en yakınının tahmini tarihi (ISO 8601); bekleyen yoksa null. İlk gerçek ödemesi alınmış davette
   * kesin tarih (`reward_due_at`); ücretsiz ayındaki arkadaşta ilk ücretli faturası (dönem sonu) + bekleme süresi.
   */
  readonly nextRewardAt: string | null;
  /** Hesabın süren ücretsiz erişimi var mı: ödenecek fatura olmadığından ödül uygulanmaz (`referrer_complimentary`). */
  readonly complimentary: boolean;
  readonly rewardsLeftThisYear: number;
  readonly rewardsPerYear: number;
  readonly rewardUsd: number;
  readonly holdDays: number;
}

/** Hesabın kodu; yoksa üretilir (eşzamanlı istek ve çok düşük olasılıklı çakışma yeniden denenir). */
async function ensureReferralCode(db: D1Database, userId: string, nowMs: number): Promise<string> {
  for (let attempt: number = 1; attempt <= 5; attempt += 1) {
    const existing: { code: string } | null = await db.prepare("SELECT code FROM referral_codes WHERE user_id = ?").bind(userId).first<{ code: string }>();
    if (existing !== null) {
      return existing.code;
    }
    await db
      .prepare("INSERT OR IGNORE INTO referral_codes (user_id, code, created_at) VALUES (?, ?, ?)")
      .bind(userId, newReferralCode(), nowMs)
      .run();
  }
  log("alert", "referral_code_not_created", { userId });
  throw new ApiError("internal_error", "Davet kodu oluşturulamadı.");
}

/** Davet edenin sayaçları; `next_reward_at` bekleyen ödüllerin en yakın tahmini tarihi (ms; yoksa null). */
interface ReferrerCounts {
  readonly joined: number;
  readonly rewarded: number;
  readonly pending: number;
  readonly recent: number;
  readonly next_reward_at: number | null;
}

/** Davet edenin son 365 günde aldığı ödül sayısı (`rewarded_at` penceresi). */
export async function recentRewardCount(db: D1Database, referrerUserId: string, nowMs: number): Promise<number> {
  const row: { count: number } | null = await db
    .prepare("SELECT COUNT(*) AS count FROM referral_redemptions WHERE referrer_user_id = ? AND status = 'granted' AND rewarded_at > ?")
    .bind(referrerUserId, nowMs - referralRewardWindowMs)
    .first<{ count: number }>();
  return row?.count ?? 0;
}

/**
 * Hesabın davet özeti: program açık ve abonelik erişimi varsa kod (yoksa üretilir) ve bağlantı; sayaçlar her durumda
 * (eski davetlerin ödülleri görünür).
 */
export async function referralSummary(db: D1Database, config: Config, userId: string, now: Date): Promise<ReferralSummary> {
  const nowMs: number = now.getTime();
  const subscription: SubscriptionState | null = await subscriptionState(db, userId);
  const eligible: boolean = config.referralPolicy === "on" && subscriptionAccess(subscription, now, config.pastDueGraceMs) !== "none";
  const code: string | null = eligible ? await ensureReferralCode(db, userId, nowMs) : null;
  const counts: ReferrerCounts | null = await db
    .prepare(
      `SELECT COALESCE(SUM(CASE WHEN joined_at IS NOT NULL THEN 1 ELSE 0 END), 0) AS joined,
         COALESCE(SUM(CASE WHEN status = 'granted' THEN 1 ELSE 0 END), 0) AS rewarded,
         COALESCE(SUM(CASE WHEN status IN ('joined', 'qualified') THEN 1 ELSE 0 END), 0) AS pending,
         COALESCE(SUM(CASE WHEN status = 'granted' AND rewarded_at > ?2 THEN 1 ELSE 0 END), 0) AS recent,
         MIN(CASE WHEN r.status = 'qualified' THEN r.reward_due_at
                  WHEN r.status = 'joined' THEN (SELECT s.current_period_end FROM subscriptions s WHERE s.stripe_subscription_id = r.stripe_subscription_id) + ?3
             END) AS next_reward_at
       FROM referral_redemptions r WHERE referrer_user_id = ?1`,
    )
    .bind(userId, nowMs - referralRewardWindowMs, referralHoldMs)
    .first<ReferrerCounts>();
  const complimentary: boolean = subscription !== null && subscription.complimentary && !isTerminalSubscription(subscription, now);
  return {
    enabled: config.referralPolicy === "on",
    code,
    inviteUrl: code === null ? null : inviteUrl(config.siteOrigin, code),
    joined: counts?.joined ?? 0,
    rewarded: counts?.rewarded ?? 0,
    pending: counts?.pending ?? 0,
    nextRewardAt: counts === null || counts.next_reward_at === null ? null : new Date(counts.next_reward_at).toISOString(),
    complimentary,
    rewardsLeftThisYear: Math.max(0, referralRewardsPerYear - (counts?.recent ?? 0)),
    rewardsPerYear: referralRewardsPerYear,
    rewardUsd: config.priceUsdMonthly,
    holdDays: referralHoldDays,
  };
}

/** Hesabın giriş kimliğinin özeti (deneme defteriyle aynı: `trialIdentityHash`); kimlik yoksa `unauthorized`. */
async function userIdentityHash(db: D1Database, config: Config, userId: string): Promise<string> {
  const identity: { provider: IdentityProvider; subject: string } | null = await db
    .prepare("SELECT provider, subject FROM auth_identities WHERE user_id = ? ORDER BY provider, subject LIMIT 1")
    .bind(userId)
    .first<{ provider: IdentityProvider; subject: string }>();
  if (identity === null) {
    throw new ApiError("unauthorized", "Hesap bulunamadı.");
  }
  return trialIdentityHash(config.secrets.trialHash, identity.provider, identity.subject);
}

/**
 * İki hesap aynı cihazı paylaşıyor mu: birinin doğrulattığı ya da toplantısında gösterdiği App Attest cihazı diğerinde
 * de görünüyor (aynı Mac'te iki hesap). App Attest anahtarı kurulum başınadır; cihazı olmayan hesaplar eşleşmez.
 */
export async function sharesDevice(db: D1Database, left: string, right: string): Promise<boolean> {
  const devicesOf = (param: string): string =>
    `SELECT device_id AS id FROM meeting_sessions WHERE user_id = ${param} AND device_id IS NOT NULL
     UNION SELECT id FROM devices WHERE attested_by_user_id = ${param}`;
  const row: { shared: number } | null = await db
    .prepare(`SELECT EXISTS (SELECT id FROM (${devicesOf("?1")}) INTERSECT SELECT id FROM (${devicesOf("?2")})) AS shared`)
    .bind(left, right)
    .first<{ shared: number }>();
  return (row?.shared ?? 0) === 1;
}

/** Kabul edilmiş davet: Checkout'a eklenir ve davet satırına yazılır. */
export interface AcceptedReferral {
  readonly code: string;
  readonly referrerUserId: string;
  readonly referredIdentityHash: string;
}

/** Reddedilen kodu loglar (kod yazılmaz) ve hatayı döndürür. */
function rejected(userId: string, error: ApiError): ApiError {
  log("info", "referral_rejected", { userId, reason: error.code });
  return error;
}

/**
 * Kodu `userId` için doğrular (`POST /v1/referral/validate` ve Checkout aynı denetimi yapar):
 * - program kapalıysa `referral_unavailable`;
 * - biçimi bozuk, bilinmeyen ya da sahibinin abonelik erişimi olmayan kod `referral_invalid`;
 * - kendi kodu ya da sahibiyle aynı cihazı paylaşan hesap `referral_self`;
 * - daha önce abonelik açmış (satırı olan) hesap ya da aynı giriş kimliğiyle daha önce davetle abone olmuş (hesabı
 *   silinmiş olsa da) kimlik `referral_not_eligible`.
 */
export async function requireReferral(db: D1Database, config: Config, userId: string, rawCode: string, now: Date): Promise<AcceptedReferral> {
  if (config.referralPolicy === "off") {
    throw rejected(userId, new ApiError("referral_unavailable", "Davet programı şu an kapalı."));
  }
  const code: string = normalizeReferralCode(rawCode);
  const invalid: ApiError = new ApiError("referral_invalid", "Bu davet kodu geçerli değil.");
  if (!isReferralCodeShape(code)) {
    throw rejected(userId, invalid);
  }
  const owner: { user_id: string } | null = await db.prepare("SELECT user_id FROM referral_codes WHERE code = ?").bind(code).first<{ user_id: string }>();
  if (owner === null) {
    throw rejected(userId, invalid);
  }
  if (owner.user_id === userId) {
    throw rejected(userId, new ApiError("referral_self", "Kendi davet kodunu kullanamazsın."));
  }
  if (subscriptionAccess(await subscriptionState(db, owner.user_id), now, config.pastDueGraceMs) === "none") {
    throw rejected(userId, invalid);
  }
  const notEligible: ApiError = new ApiError("referral_not_eligible", "Davet kodu yalnızca ilk kez abone olan hesaplar içindir.");
  const subscribedBefore: { found: number } | null = await db
    .prepare("SELECT EXISTS (SELECT 1 FROM subscriptions WHERE user_id = ?) AS found")
    .bind(userId)
    .first<{ found: number }>();
  if ((subscribedBefore?.found ?? 0) === 1) {
    throw rejected(userId, notEligible);
  }
  const identityHash: string = await userIdentityHash(db, config, userId);
  // Aynı kimliğin abonelik açmış daveti (hesap silinmiş olsa da) ya da başka hesabın satırı: ikinci indirim yok.
  const usedBefore: { found: number } | null = await db
    .prepare(
      `SELECT EXISTS (SELECT 1 FROM referral_redemptions WHERE referred_identity_hash = ?1
         AND (joined_at IS NOT NULL OR referred_user_id IS NULL OR referred_user_id <> ?2)) AS found`,
    )
    .bind(identityHash, userId)
    .first<{ found: number }>();
  if ((usedBefore?.found ?? 0) === 1) {
    throw rejected(userId, notEligible);
  }
  if (await sharesDevice(db, owner.user_id, userId)) {
    throw rejected(userId, new ApiError("referral_self", "Bu davet kodu bu Mac'te kullanılamaz."));
  }
  return { code, referrerUserId: owner.user_id, referredIdentityHash: identityHash };
}

/**
 * Checkout oturumu açılırken davet satırını yazan ifadeler: hesabın abonelik açılmamış eski satırı silinir; kod varsa
 * `checkout` durumunda yeni satır eklenir. Kodsuz Checkout satırı yalnızca siler (ödenen son oturum hangisiyse satır
 * onu yansıtır: önceki açık oturumlar zaten sona erdirilir).
 */
export function referralCheckoutStatements(db: D1Database, userId: string, referral: AcceptedReferral | null, nowMs: number): D1PreparedStatement[] {
  const clear: D1PreparedStatement = db.prepare("DELETE FROM referral_redemptions WHERE referred_user_id = ? AND joined_at IS NULL").bind(userId);
  if (referral === null) {
    return [clear];
  }
  return [
    clear,
    db
      .prepare(
        `INSERT INTO referral_redemptions (id, referred_user_id, referred_identity_hash, referrer_user_id, code, status, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 'checkout', ?, ?)`,
      )
      .bind(randomId(), userId, referral.referredIdentityHash, referral.referrerUserId, referral.code, nowMs, nowMs),
  ];
}

/** Ödenmiş faturanın davetle ilgili bilgisi (`invoice.paid`). */
export interface PaidInvoice {
  readonly userId: string;
  readonly subscriptionId: string;
  readonly invoiceId: string;
  /** Aboneliğin Checkout'ta yazılan davet kodu (`metadata.referral_code`); kodsuz abonelikte null. */
  readonly referralCode: string | null;
  /** Ödenen tutar (sent); davetle aylık aboneliğin ilk faturası 0'dır. */
  readonly amountPaid: number;
  readonly nowMs: number;
}

/**
 * `invoice.paid` ifadeleri (sırayla, aynı toplu işlemde):
 * - kodla açılan aboneliğin faturası (`referralCode` satırın koduyla aynı): `checkout` → `joined`, abonelik yazılır;
 * - sıfırdan büyük ödeme ve aynı abonelik: `joined` → `qualified`, ödül `referralHoldMs` sonra verilir. Yıllıkta ilk
 *   fatura ikisini birden yapar; aylıkta ilk (ücretsiz) ay `joined`, ikinci ayın ödemesi `qualified` olur.
 */
export function referralInvoicePaidStatements(db: D1Database, paid: PaidInvoice): D1PreparedStatement[] {
  const joined: D1PreparedStatement[] =
    paid.referralCode === null
      ? []
      : [
          db
            .prepare(
              `UPDATE referral_redemptions SET status = 'joined', stripe_subscription_id = ?2, joined_at = ?3, updated_at = ?3
               WHERE referred_user_id = ?1 AND status = 'checkout' AND code = ?4`,
            )
            .bind(paid.userId, paid.subscriptionId, paid.nowMs, paid.referralCode),
        ];
  const qualified: D1PreparedStatement[] =
    paid.amountPaid > 0
      ? [
          db
            .prepare(
              `UPDATE referral_redemptions SET status = 'qualified', qualifying_invoice_id = ?3, qualified_at = ?4, reward_due_at = ?5,
                 updated_at = ?4
               WHERE referred_user_id = ?1 AND status = 'joined' AND stripe_subscription_id = ?2`,
            )
            .bind(paid.userId, paid.subscriptionId, paid.invoiceId, paid.nowMs, paid.nowMs + referralHoldMs),
        ]
      : [];
  return [...joined, ...qualified];
}

/** Aboneliğin bekleyen ödülünü düşüren ifade (iade). */
export function referralVoidBySubscriptionStatement(db: D1Database, subscriptionId: string, reason: ReferralVoidReason, nowMs: number): D1PreparedStatement {
  return db
    .prepare(
      `UPDATE referral_redemptions SET status = 'void', void_reason = ?, updated_at = ?
       WHERE stripe_subscription_id = ? AND status IN ('joined', 'qualified')`,
    )
    .bind(reason, nowMs, subscriptionId);
}

/** Davet edilen hesabın bekleyen ödülünü düşüren ifade (itiraz). */
export function referralVoidByReferredStatement(db: D1Database, referredUserId: string, reason: ReferralVoidReason, nowMs: number): D1PreparedStatement {
  return db
    .prepare(
      `UPDATE referral_redemptions SET status = 'void', void_reason = ?, updated_at = ?
       WHERE referred_user_id = ? AND status IN ('joined', 'qualified')`,
    )
    .bind(reason, nowMs, referredUserId);
}

/**
 * Hesap silinirken davet ifadeleri: kodu silinir; abonelik açmamış satırı silinir; davetle abone olmuş satırında hesap
 * bağı kaldırılır (kimlik özeti ve zamanlar kalır, `cleanup.ts` 730 gün sonra siler); davet ettiklerinin satırlarında
 * davet eden bağı kaldırılır ve bekleyen ödül düşer.
 */
export function referralDeletionStatements(db: D1Database, userId: string, nowMs: number): D1PreparedStatement[] {
  return [
    db.prepare("DELETE FROM referral_codes WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM referral_redemptions WHERE referred_user_id = ? AND joined_at IS NULL").bind(userId),
    db.prepare("UPDATE referral_redemptions SET referred_user_id = NULL, updated_at = ? WHERE referred_user_id = ?").bind(nowMs, userId),
    db
      .prepare(
        `UPDATE referral_redemptions SET referrer_user_id = NULL,
           void_reason = CASE WHEN status IN ('checkout', 'joined', 'qualified') THEN 'referrer_deleted' ELSE void_reason END,
           status = CASE WHEN status IN ('checkout', 'joined', 'qualified') THEN 'void' ELSE status END,
           updated_at = ?
         WHERE referrer_user_id = ?`,
      )
      .bind(nowMs, userId),
  ];
}

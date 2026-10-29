import { closeStripeForDeletion } from "./billing";
import type { Config } from "./config";
import { log } from "./log";
import type { Platform } from "./platform";
import { referralDeletionStatements } from "./referrals";
import { userReservationRemovalStatements } from "./reservations";
import { ledgerOnDeletionStatement, trialIdentityHash } from "./trialLedger";
import type { IdentityProvider } from "./auth/users";
import { dayKey } from "./usage";

/** Hesabın giriş kimliği. */
interface StoredIdentity {
  readonly provider: IdentityProvider;
  readonly subject: string;
}

/**
 * Hesabın tüm satırlarını tek D1 toplu işleminde (tek işlem; yarıda kalmaz) silen ifadeler. Sıra yabancı anahtarlara
 * göredir (önce çocuk satırlar). Oturum aileleri ve yenileme jetonları silinir: hesabın tüm erişim ve yenileme
 * jetonları hemen geçersizdir. Kötüye kullanım sayaçları hesap bağı olmadan kalır:
 * - her giriş kimliğinin deneme defteri satırına (`trial_identity_ledger`, kimliğin HMAC özeti `identityHashes`)
 *   hesabın harcadığı deneme sayısı ve cihaz doğrulaması yazılır (satırlar silinmeden önce, aynı işlemde): aynı
 *   kimlikle yeniden açılan hesap yeni deneme almaz. Hiç deneme harcamamış hesap için satır yazılmaz; satır son
 *   güncellemeden 730 gün sonra silinir (`cleanup.ts`);
 * - bugünkü deneme başlangıcı IP özeti başına günlük sayaca (`deleted_trial_starts`) eklenir; silip yeniden açarak IP
 *   başına günlük deneme sınırı aşılamaz;
 * - hesabın kaydettiği cihazları başka hesapların toplantıları da göstermiş olabilir: o toplantıların cihaz bağı
 *   kaldırılır (cihaz başına deneme sayacı App Attest anahtarı başınadır ve yeni anahtar her zaman üretilebilir; bu,
 *   o sınırı mevcut durumdan daha fazla zayıflatmaz).
 * Hesaba bağlı raporlar (geri bildirim, çökme) bağı kaldırılarak değil, silinerek gider: serbest metin, e-posta ve
 * çökme yükü kişisel veri taşıyabilir; silme hakkı bunları kapsar. Jetonsuz gönderilmiş raporlar (site iletişim formu)
 * hesaba bağlanamaz ve 180 günlük saklama süresiyle silinir. Abonelik iptal nedenleri (`subscription_cancellations`;
 * serbest yorum içerebilir) de silinir. Davet: kodu ve abonelik açmamış davet satırı silinir; davetle abone olduysa
 * satırın hesap bağı kaldırılır, kimlik özeti kalır (aynı kimlik ikinci kez davet indirimi alamaz; 730 gün); davet
 * ettiklerinin satırlarında davet eden bağı kaldırılır, bekleyen ödülleri düşer (`referralDeletionStatements`).
 * Süren ayırmaların tahmini maliyeti silinmeden günlük harcamaya yazılır (`userReservationRemovalStatements`): silme
 * sırasında süren çağrı kesinleşirken yabancı anahtar hatası almaz, harcama da kaybolmaz.
 * `daily_spend` (toplam, kişisel değil), `downloads`, `download_sources`, `download_visitors`, `ops_events`,
 * `used_nonces` ve `stripe_events` hesaba bağlı değildir.
 */
function accountDeletionStatements(db: D1Database, userId: string, identityHashes: readonly string[], now: Date): D1PreparedStatement[] {
  return [
    ...identityHashes.map((identityHash: string): D1PreparedStatement => ledgerOnDeletionStatement(db, identityHash, userId, now)),
    db
      .prepare(
        `INSERT INTO deleted_trial_starts (ip_hash, day, accounts)
         SELECT ip_hash, day, 1 FROM trial_starts WHERE user_id = ? AND day = ?
         ON CONFLICT(ip_hash, day) DO UPDATE SET accounts = accounts + 1`,
      )
      .bind(userId, dayKey(now)),
    db.prepare("DELETE FROM trial_starts WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM reports WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM subscription_cancellations WHERE user_id = ?").bind(userId),
    ...referralDeletionStatements(db, userId, now.getTime()),
    db.prepare("DELETE FROM auth_identities WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM refresh_tokens WHERE family_id IN (SELECT id FROM refresh_families WHERE user_id = ?)").bind(userId),
    db.prepare("DELETE FROM refresh_families WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM device_challenges WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM transcription_results WHERE user_id = ?").bind(userId),
    ...userReservationRemovalStatements(db, userId),
    db.prepare("DELETE FROM meeting_sessions WHERE user_id = ?").bind(userId),
    db
      .prepare("UPDATE meeting_sessions SET device_id = NULL WHERE device_id IN (SELECT id FROM devices WHERE attested_by_user_id = ?)")
      .bind(userId),
    db.prepare("DELETE FROM devices WHERE attested_by_user_id = ?").bind(userId),
    db.prepare("DELETE FROM monthly_usage WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM daily_usage WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM subscriptions WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM stripe_customers WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM users WHERE id = ?").bind(userId),
  ];
}

/**
 * Hesabı siler (GDPR silme hakkı). Önce Stripe'taki açık Checkout oturumları sona erdirilir ve bitmemiş abonelikler
 * hemen iptal edilir (yeniden denemeyle; `closeStripeForDeletion`);
 * Stripe başarısız olursa hiçbir satır silinmez ve istemci yeniden dener. Sonra hesabın tüm satırları tek işlemde
 * silinir; kimliklerin deneme defteri aynı işlemde önce yazılır. Tekrar çağrı güvenlidir: iptal edilmiş abonelik atlanır, olmayan satır silinmez. Stripe'taki müşteri ve
 * faturalar vergi kayıtları için Stripe'ta kalır; sunucuda onları bu hesaba bağlayan satır kalmaz.
 */
export async function deleteAccount(db: D1Database, platform: Platform, config: Config, userId: string, now: Date): Promise<void> {
  const canceledSubscriptions: number = await closeStripeForDeletion(db, platform, config, userId);
  const identities: D1Result<StoredIdentity> = await db
    .prepare("SELECT provider, subject FROM auth_identities WHERE user_id = ?")
    .bind(userId)
    .all<StoredIdentity>();
  const identityHashes: string[] = await Promise.all(
    identities.results.map((identity: StoredIdentity): Promise<string> => trialIdentityHash(config.secrets.trialHash, identity.provider, identity.subject)),
  );
  await db.batch(accountDeletionStatements(db, userId, identityHashes, now));
  log("info", "account_deleted", { userId, canceledSubscriptions });
}

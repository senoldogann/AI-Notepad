import { cancelAllSubscriptions } from "./billing";
import type { Config } from "./config";
import { log } from "./log";
import type { Platform } from "./platform";
import { dayKey } from "./usage";

/**
 * Hesabın tüm satırlarını tek D1 toplu işleminde (tek işlem; yarıda kalmaz) silen ifadeler. Sıra yabancı anahtarlara
 * göredir (önce çocuk satırlar). Oturum aileleri ve yenileme jetonları silinir: hesabın tüm erişim ve yenileme
 * jetonları hemen geçersizdir. Kötüye kullanım sayaçları hesap bağı olmadan kalır:
 * - bugünkü deneme başlangıcı IP özeti başına günlük sayaca (`deleted_trial_starts`) eklenir; silip yeniden açarak IP
 *   başına günlük deneme sınırı aşılamaz;
 * - hesabın kaydettiği cihazları başka hesapların toplantıları da göstermiş olabilir: o toplantıların cihaz bağı
 *   kaldırılır (cihaz başına deneme sayacı App Attest anahtarı başınadır ve yeni anahtar her zaman üretilebilir; bu,
 *   o sınırı mevcut durumdan daha fazla zayıflatmaz).
 * `daily_spend` (toplam, kişisel değil), `used_nonces` ve `stripe_events` hesaba bağlı değildir.
 */
function accountDeletionStatements(db: D1Database, userId: string, now: Date): D1PreparedStatement[] {
  return [
    db
      .prepare(
        `INSERT INTO deleted_trial_starts (ip_hash, day, accounts)
         SELECT ip_hash, day, 1 FROM trial_starts WHERE user_id = ? AND day = ?
         ON CONFLICT(ip_hash, day) DO UPDATE SET accounts = accounts + 1`,
      )
      .bind(userId, dayKey(now)),
    db.prepare("DELETE FROM trial_starts WHERE user_id = ?").bind(userId),
    db
      .prepare("DELETE FROM email_login_tokens WHERE email IN (SELECT subject FROM auth_identities WHERE user_id = ? AND provider = 'email')")
      .bind(userId),
    db.prepare("DELETE FROM auth_identities WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM refresh_tokens WHERE family_id IN (SELECT id FROM refresh_families WHERE user_id = ?)").bind(userId),
    db.prepare("DELETE FROM refresh_families WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM device_challenges WHERE user_id = ?").bind(userId),
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
 * Hesabı siler (GDPR silme hakkı). Önce Stripe'taki bitmemiş abonelikler hemen iptal edilir (yeniden denemeyle);
 * Stripe başarısız olursa hiçbir satır silinmez ve istemci yeniden dener. Sonra hesabın tüm satırları tek işlemde
 * silinir. Tekrar çağrı güvenlidir: iptal edilmiş abonelik atlanır, olmayan satır silinmez. Stripe'taki müşteri ve
 * faturalar vergi kayıtları için Stripe'ta kalır; sunucuda onları bu hesaba bağlayan satır kalmaz.
 */
export async function deleteAccount(db: D1Database, platform: Platform, config: Config, userId: string, now: Date): Promise<void> {
  const canceledSubscriptions: number = await cancelAllSubscriptions(db, platform, config, userId);
  await db.batch(accountDeletionStatements(db, userId, now));
  log("info", "account_deleted", { userId, canceledSubscriptions });
}

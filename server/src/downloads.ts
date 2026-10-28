import { errorName, log } from "./log";
import { dayKey } from "./usage";

/**
 * Bugünün (UTC) indirme sayacını bir artırır. Yalnızca gün ve sayı saklanır: IP, tarayıcı ya da başka bir tanımlayıcı
 * yok.
 *
 * Bilinçli istisna (projenin "hatayı yutma" kuralına karşı tek izinli durum): D1 yazımı başarısız olursa hata adıyla
 * uyarı loglanır ve fonksiyon normal döner. İndirme istatistik yüzünden engellenmemeli; kayıp yalnızca bir sayaçtır ve
 * log uyarısı onu görünür kılar.
 */
export async function countDownload(db: D1Database, now: Date): Promise<void> {
  try {
    await db
      .prepare("INSERT INTO downloads (day, count) VALUES (?, 1) ON CONFLICT(day) DO UPDATE SET count = count + 1")
      .bind(dayKey(now))
      .run();
  } catch (error: unknown) {
    log("warn", "download_count_failed", { error: errorName(error) });
  }
}

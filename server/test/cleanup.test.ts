import { createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { CleanupFailedError, type CleanupReport, cleanupExpiredRows } from "../src/cleanup";
import { randomId } from "../src/crypto";
import worker from "../src/index";

const dayMs: number = 86_400_000;
const nowMs: number = Date.UTC(2026, 9, 15, 12, 0, 0);
const now: Date = new Date(nowMs);

function day(offsetDays: number): string {
  return new Date(nowMs + offsetDays * dayMs).toISOString().slice(0, 10);
}

async function ids(sql: string): Promise<string[]> {
  const rows = await env.DB.prepare(sql).all<{ id: string }>();
  return rows.results.map((row: { id: string }): string => row.id).sort();
}

async function insertUser(): Promise<string> {
  const userId: string = randomId();
  await env.DB.prepare("INSERT INTO users (id, created_at) VALUES (?, 0)").bind(userId).run();
  return userId;
}

describe("süresi dolmuş satırların temizliği", () => {
  it("süresi dolmuş ya da kullanılmış satırları siler, denetimlerin baktığı satırları korur", async () => {
    const first: string = await insertUser();
    const second: string = await insertUser();
    const later: number = nowMs + 60_000;
    await env.DB.batch([
      env.DB.prepare("INSERT INTO used_nonces (nonce_hash, expires_at) VALUES ('n_old', ?), ('n_new', ?)").bind(nowMs - 1, later),
      env.DB.prepare(
        `INSERT INTO transcription_results (key_hash, user_id, meeting_id, ciphertext, iv, created_at, expires_at) VALUES
           ('t_old', ?1, 'm', x'00', x'00', 0, ?2), ('t_new', ?1, 'm', x'00', x'00', 0, ?3)`,
      ).bind(first, nowMs - 1, later),
      env.DB.prepare(
        `INSERT INTO duplicate_subscriptions (stripe_subscription_id, user_id, stripe_customer_id, created_at) VALUES
           ('sub_dup_old', ?1, 'cus_x', ?2), ('sub_dup_new', ?1, 'cus_x', ?3)`,
      ).bind(first, nowMs - 401 * dayMs, nowMs - 10 * dayMs),
      env.DB.prepare(
        `INSERT INTO reports (id, kind, status, created_at, summary) VALUES
           ('r_old', 'feedback', 'open', ?, 'x'), ('r_old_done', 'crash', 'done', ?, 'x'), ('r_recent', 'contact', 'open', ?, 'x')`,
      ).bind(nowMs - 181 * dayMs, nowMs - 200 * dayMs, nowMs - 179 * dayMs),
      env.DB.prepare(
        `INSERT INTO device_challenges (challenge_hash, user_id, purpose, created_at, expires_at, used_at) VALUES
           ('c_expired', ?1, 'assert', 0, ?2, NULL), ('c_used', ?1, 'assert', 0, ?3, ?4), ('c_live', ?1, 'attest', 0, ?3, NULL)`,
      ).bind(first, nowMs - 1, later, nowMs - 10),
      env.DB.prepare(
        `INSERT INTO refresh_families (id, user_id, created_at, revoked_at) VALUES
           ('f_live', ?1, 0, NULL), ('f_revoked', ?1, 0, ?2), ('f_empty', ?1, 0, NULL)`,
      ).bind(first, nowMs - 10),
      env.DB.prepare(
        `INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at, used_at) VALUES
           ('t_live', 'f_live', 0, ?1, NULL), ('t_used_live', 'f_live', 0, ?1, ?2), ('t_used_older', 'f_live', 0, ?1, ?3),
           ('t_expired', 'f_live', 0, ?2, NULL), ('t_revoked', 'f_revoked', 0, ?1, NULL)`,
      ).bind(later, nowMs - 10, nowMs - 20),
      env.DB.prepare("INSERT INTO stripe_events (id, type, processed_at) VALUES ('evt_old', 'x', ?), ('evt_recent', 'x', ?)").bind(
        nowMs - 91 * dayMs,
        nowMs - dayMs,
      ),
      env.DB.prepare("INSERT INTO trial_starts (user_id, ip_hash, day, created_at) VALUES (?, 'ip', ?, 0), (?, 'ip', ?, 0)").bind(
        first,
        day(-1),
        second,
        day(0),
      ),
      env.DB.prepare("INSERT INTO deleted_trial_starts (ip_hash, day, accounts) VALUES ('ip', ?, 1), ('ip', ?, 2)").bind(day(-1), day(0)),
      env.DB.prepare("INSERT INTO daily_spend (day, micro_usd) VALUES (?, 1), (?, 1), (?, 1)").bind(day(-91), day(-89), day(0)),
      env.DB.prepare("INSERT INTO daily_usage (user_id, day) VALUES (?1, ?2), (?1, ?3), (?1, ?4)").bind(first, day(-3), day(-1), day(0)),
      env.DB.prepare(
        "INSERT INTO trial_identity_ledger (identity_hash, trial_meetings_used, device_verified, updated_at) VALUES ('l_old', 3, 1, ?), ('l_recent', 1, 0, ?)",
      ).bind(nowMs - 731 * dayMs, nowMs - 729 * dayMs),
      // 13 aylık saklama: toplantılar, aylık kullanım, kullanılmayan cihazlar.
      env.DB.prepare(
        `INSERT INTO devices (id, public_key_spki, sign_count, environment, validation_category, bundle_version, receipt,
           attested_by_user_id, created_at, last_used_at) VALUES
           ('d_old', 's', 0, 'development', 3, '1', 'r', ?1, 0, ?2), ('d_recent', 's', 0, 'development', 3, '1', 'r', ?1, 0, ?3)`,
      ).bind(first, nowMs - 396 * dayMs, nowMs - 394 * dayMs),
      env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, device_id, kind, started_at, max_ends_at, token_budget) VALUES
           ('m_old_trial', ?1, 'd_old', 'trial', ?2, ?2, 1), ('m_old_paid', ?1, NULL, 'subscription', ?2, ?2, 1),
           ('m_recent_trial', ?1, 'd_old', 'trial', ?3, ?3, 1)`,
      ).bind(first, nowMs - 396 * dayMs, nowMs - 394 * dayMs),
      env.DB.prepare("INSERT INTO monthly_usage (user_id, month) VALUES (?1, ?2), (?1, ?3)").bind(
        first,
        new Date(nowMs - 430 * dayMs).toISOString().slice(0, 7),
        new Date(nowMs - 360 * dayMs).toISOString().slice(0, 7),
      ),
    ]);

    const report: CleanupReport = await cleanupExpiredRows(env.DB, now, { batchSize: 2, maxBatchesPerTable: 10 });
    expect(report).toEqual({
      usage_reservations: 0,
      meeting_sessions: 2,
      devices: 1,
      used_nonces: 1,
      transcription_results: 1,
      device_challenges: 2,
      refresh_tokens: 2,
      refresh_tokens_superseded: 1,
      refresh_families: 2,
      stripe_events: 1,
      duplicate_subscriptions: 1,
      trial_starts: 1,
      deleted_trial_starts: 1,
      daily_spend: 1,
      daily_usage: 1,
      monthly_usage: 1,
      reports: 2,
      trial_identity_ledger: 1,
    });
    // Silinen eski deneme toplantısı kullanıcının devraldığı denemeye eklendi; başlangıç korunur.
    const user = await env.DB.prepare("SELECT carried_trial_meetings, trial_started_at FROM users WHERE id = ?").bind(first).first<{
      carried_trial_meetings: number;
      trial_started_at: number;
    }>();
    expect(user).toEqual({ carried_trial_meetings: 1, trial_started_at: nowMs - 396 * dayMs });
    expect(await ids("SELECT id FROM meeting_sessions")).toEqual(["m_recent_trial"]);
    // Kullanılmayan cihaz silindi, ona bağlı yeni toplantının cihaz bağı kalktı.
    expect(await ids("SELECT id FROM devices")).toEqual(["d_recent"]);
    expect(await ids("SELECT COALESCE(device_id, 'yok') AS id FROM meeting_sessions")).toEqual(["yok"]);
    expect(await ids("SELECT month AS id FROM monthly_usage")).toEqual([new Date(nowMs - 360 * dayMs).toISOString().slice(0, 7)]);
    expect(await ids("SELECT nonce_hash AS id FROM used_nonces")).toEqual(["n_new"]);
    expect(await ids("SELECT key_hash AS id FROM transcription_results")).toEqual(["t_new"]);
    expect(await ids("SELECT stripe_subscription_id AS id FROM duplicate_subscriptions")).toEqual(["sub_dup_new"]);
    // Raporlar durumundan bağımsız 180 gün tutulur.
    expect(await ids("SELECT id FROM reports")).toEqual(["r_recent"]);
    expect(await ids("SELECT challenge_hash AS id FROM device_challenges")).toEqual(["c_live"]);
    // Ailenin en son kullanılmış jetonu yeniden kullanım algılaması için kalır; daha eskisi silinir.
    expect(await ids("SELECT token_hash AS id FROM refresh_tokens")).toEqual(["t_live", "t_used_live"]);
    expect(await ids("SELECT id FROM refresh_families")).toEqual(["f_live"]);
    expect(await ids("SELECT id FROM stripe_events")).toEqual(["evt_recent"]);
    expect(await ids("SELECT user_id AS id FROM trial_starts")).toEqual([second]);
    expect(await ids("SELECT day AS id FROM deleted_trial_starts")).toEqual([day(0)]);
    expect(await ids("SELECT day AS id FROM daily_spend")).toEqual([day(-89), day(0)]);
    expect(await ids("SELECT day AS id FROM daily_usage")).toEqual([day(-1), day(0)]);
    // Kimlik deneme defteri son güncellemeden 730 gün tutulur.
    expect(await ids("SELECT identity_hash AS id FROM trial_identity_ledger")).toEqual(["l_recent"]);
  });

  it("tablo başına tur sayısı sınırlıdır; kalan satırlar sonraki çalışmada silinir", async () => {
    const values: string = Array.from({ length: 5 }, (_: unknown, index: number): string => `('limit_${index}', ${nowMs - 1})`).join(", ");
    await env.DB.prepare(`INSERT INTO used_nonces (nonce_hash, expires_at) VALUES ${values}`).run();
    const warnings = vi.spyOn(console, "warn");
    const first: CleanupReport = await cleanupExpiredRows(env.DB, now, { batchSize: 2, maxBatchesPerTable: 2 });
    expect(first["used_nonces"]).toBe(4);
    expect(warnings.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"cleanup_incomplete","table":"used_nonces"'))).toBe(true);
    warnings.mockRestore();
    const second: CleanupReport = await cleanupExpiredRows(env.DB, now, { batchSize: 2, maxBatchesPerTable: 2 });
    expect(second["used_nonces"]).toBe(1);
  });

  it("bir adımın hatası diğerlerini durdurmaz; alarm yazılır ve sonunda toplu hata fırlatılır", async () => {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO stripe_events (id, type, processed_at) VALUES ('evt_kilitli', 'x', ?)").bind(nowMs - 100 * dayMs),
      env.DB.prepare("INSERT INTO used_nonces (nonce_hash, expires_at) VALUES ('n_hata_sonrasi', ?)").bind(nowMs - 1),
      env.DB.prepare("CREATE TRIGGER stripe_events_kilit BEFORE DELETE ON stripe_events BEGIN SELECT RAISE(ABORT, 'kilitli'); END"),
    ]);
    const alerts = vi.spyOn(console, "error");
    try {
      const failure: unknown = await cleanupExpiredRows(env.DB, now, { batchSize: 100, maxBatchesPerTable: 2 }).then(
        (): null => null,
        (error: unknown): unknown => error,
      );
      expect(failure).toBeInstanceOf(CleanupFailedError);
      expect((failure as CleanupFailedError).steps).toEqual(["stripe_events"]);
      expect((failure as CleanupFailedError).report["used_nonces"]).toBe(1);
      expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"cleanup_failed","step":"stripe_events"'))).toBe(true);
    } finally {
      alerts.mockRestore();
      await env.DB.prepare("DROP TRIGGER stripe_events_kilit").run();
    }
    // Hatadan sonraki adımlar çalıştı.
    expect(await ids("SELECT nonce_hash AS id FROM used_nonces WHERE nonce_hash = 'n_hata_sonrasi'")).toEqual([]);
  });

  it("zamanlanmış işleyici (Cron Trigger) temizliği çalıştırır", async () => {
    await env.DB.prepare("INSERT INTO used_nonces (nonce_hash, expires_at) VALUES ('cron_old', ?)").bind(nowMs - 1).run();
    const controller: ScheduledController = createScheduledController({ scheduledTime: nowMs, cron: "17 3 * * *" });
    // Bakım Apple ve Google anahtarlarını da tazeler: dış istek sahte anahtar kümesiyle yanıtlanır.
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation(async (): Promise<Response> =>
      Response.json({ keys: [{ kty: "RSA", kid: "cron-key", n: "AQAB", e: "AQAB" }] }),
    );
    await worker.scheduled(controller, env);
    fetchSpy.mockRestore();
    expect(await ids("SELECT nonce_hash AS id FROM used_nonces WHERE nonce_hash = 'cron_old'")).toEqual([]);
    expect(await ids("SELECT jwks_url AS id FROM identity_jwks ORDER BY jwks_url")).toEqual([
      "https://appleid.apple.com/auth/keys",
      "https://www.googleapis.com/oauth2/v3/certs",
    ]);
  });
});

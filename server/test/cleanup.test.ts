import { createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { type CleanupReport, cleanupExpiredRows } from "../src/cleanup";
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
           ('t_live', 'f_live', 0, ?1, NULL), ('t_used_live', 'f_live', 0, ?1, ?2), ('t_expired', 'f_live', 0, ?2, NULL),
           ('t_revoked', 'f_revoked', 0, ?1, NULL)`,
      ).bind(later, nowMs - 10),
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
    ]);

    const report: CleanupReport = await cleanupExpiredRows(env.DB, now, { batchSize: 2, maxBatchesPerTable: 10 });
    expect(report).toEqual({
      used_nonces: 1,
      device_challenges: 2,
      refresh_tokens: 2,
      refresh_families: 2,
      stripe_events: 1,
      trial_starts: 1,
      deleted_trial_starts: 1,
      daily_spend: 1,
      daily_usage: 1,
      reports: 2,
    });
    expect(await ids("SELECT nonce_hash AS id FROM used_nonces")).toEqual(["n_new"]);
    // Raporlar durumundan bağımsız 180 gün tutulur.
    expect(await ids("SELECT id FROM reports")).toEqual(["r_recent"]);
    expect(await ids("SELECT challenge_hash AS id FROM device_challenges")).toEqual(["c_live"]);
    // Kullanılmış ama süresi dolmamış jeton yeniden kullanım algılaması için kalır.
    expect(await ids("SELECT token_hash AS id FROM refresh_tokens")).toEqual(["t_live", "t_used_live"]);
    expect(await ids("SELECT id FROM refresh_families")).toEqual(["f_live"]);
    expect(await ids("SELECT id FROM stripe_events")).toEqual(["evt_recent"]);
    expect(await ids("SELECT user_id AS id FROM trial_starts")).toEqual([second]);
    expect(await ids("SELECT day AS id FROM deleted_trial_starts")).toEqual([day(0)]);
    expect(await ids("SELECT day AS id FROM daily_spend")).toEqual([day(-89), day(0)]);
    expect(await ids("SELECT day AS id FROM daily_usage")).toEqual([day(-1), day(0)]);
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

  it("zamanlanmış işleyici (Cron Trigger) temizliği çalıştırır", async () => {
    await env.DB.prepare("INSERT INTO used_nonces (nonce_hash, expires_at) VALUES ('cron_old', ?)").bind(nowMs - 1).run();
    const controller: ScheduledController = createScheduledController({ scheduledTime: nowMs, cron: "17 3 * * *" });
    await worker.scheduled(controller, env);
    expect(await ids("SELECT nonce_hash AS id FROM used_nonces WHERE nonce_hash = 'cron_old'")).toEqual([]);
  });
});

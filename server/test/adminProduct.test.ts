import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { AdminProduct, EconomicsMonth, OpsDay } from "../src/adminProduct";
import { randomId } from "../src/crypto";
import type { Env } from "../src/env";
import { type Harness, type Session, defaultHarness, envWith, expectError, grantSubscription, req, signIn, signInWithGoogle } from "./helpers";

const dayMs: number = 86_400_000;
const hourMs: number = 3_600_000;
const minuteMs: number = 60_000;
const adminSubject: string = "product-admin-7";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}` });

/** Düzeneğin saati 2026-10-15 12:00 UTC (perşembe); haftalar pazartesi başlar, ilk hafta 24 Ağustos. */
const weekStarts: readonly string[] = ["2026-08-24", "2026-08-31", "2026-09-07", "2026-09-14", "2026-09-21", "2026-09-28", "2026-10-05", "2026-10-12"];

function dayOf(nowMs: number, offsetDays: number): string {
  return new Date(nowMs + offsetDays * dayMs).toISOString().slice(0, 10);
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

async function insertUser(createdAt: number): Promise<string> {
  const userId: string = randomId();
  await env.DB.prepare("INSERT INTO users (id, created_at) VALUES (?, ?)").bind(userId, createdAt).run();
  return userId;
}

/** Ürün görünümünü yönetici olarak okur. */
async function fetchProduct(harness: Harness, admin: Session): Promise<AdminProduct> {
  const response: Response = await harness.call(req("GET", "/v1/admin/product", { token: admin.accessToken, env: adminEnv }));
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("no-store");
  return response.json<AdminProduct>();
}

/** Ayın boş ekonomisi: toplantı yok, ödeyen abone sayısı ve liste geliri verilir. */
function emptyMonth(month: string, partial: boolean, payers: number, revenue: number): EconomicsMonth {
  return {
    month,
    partial,
    meetings: 0,
    meetingHours: 0,
    meetingCostUsd: { llm: 0, elevenLabs: 0, deepgram: 0, total: 0 },
    accountLlmUsd: 0,
    perMeeting: null,
    perMeetingHour: null,
    payers: {
      users: payers,
      costUsd: 0,
      costPerUserUsd: payers === 0 ? null : 0,
      listRevenueUsd: revenue,
      grossMarginPercent: revenue === 0 ? null : 100,
    },
  };
}

describe("yönetici ürün görünümü", () => {
  // Bu dosyanın ilk testi: veritabanında yalnızca bu testin hesapları var.
  it("boş durumda tanımlı biçimi, sıfır doldurulmuş serileri ve null ortalamaları döner; yönetici olmayan 403 alır", async () => {
    const harness: Harness = await defaultHarness();
    const nowMs: number = harness.clock.nowMs;
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const other: Session = await signIn(harness);
    await expectError(await harness.call(req("GET", "/v1/admin/product", { token: other.accessToken, env: adminEnv })), 403, "forbidden");

    const product: AdminProduct = await fetchProduct(harness, admin);
    expect(product.generatedAt).toBe(iso(nowMs));
    expect(product.engagement).toEqual({
      activeLast7Days: 0,
      activeLast30Days: 0,
      weeks: weekStarts.map((weekStart: string) => ({ weekStart, activeUsers: 0, meetings: 0, meetingsPerActiveUser: null })),
    });
    // Bu haftanın kohortu: yönetici ve diğer hesap; başlamamış hafta sütunları null.
    expect(product.cohorts.map((cohort) => cohort.weekStart)).toEqual(weekStarts);
    expect(product.cohorts[0]).toEqual({ weekStart: "2026-08-24", signups: 0, activeByWeek: [0, 0, 0, 0, 0] });
    expect(product.cohorts[6]).toEqual({ weekStart: "2026-10-05", signups: 0, activeByWeek: [0, 0, null, null, null] });
    expect(product.cohorts[7]).toEqual({ weekStart: "2026-10-12", signups: 2, activeByWeek: [0, null, null, null, null] });
    expect(product.retention).toEqual({ d7: { day: 7, eligible: 0, retained: 0 }, d30: { day: 30, eligible: 0, retained: 0 } });
    expect(product.timeToStep).toEqual({
      days: 90,
      signupToFirstMeeting: { users: 0, medianSeconds: null },
      firstMeetingToFirstNote: { users: 0, medianSeconds: null },
      signupToFirstNote: { users: 0, medianSeconds: null },
    });
    expect(product.trialOutcomes).toEqual({ started: 0, converted: 0, exhausted: 0, expired: 0, active: 0 });
    expect(product.checkout).toEqual({ started: 0, paid: 0, abandoned: 0, startedLast30Days: 0, abandonedLast30Days: 0 });
    expect(product.reliability).toEqual({
      days: 30,
      meetings: 0,
      failedMeetings: 0,
      failuresByCode: [],
      endedMeetings: 0,
      notedMeetings: 0,
      medianNoteSeconds: null,
      superseded: 0,
      unended: 0,
      open: 0,
      budgetExhausted: 0,
      deepgram: { meetings: 0, baselineGrants: 3, grants: 0, withReconnects: 0, reconnects: 0 },
      onDevice: 0,
      opsDays: Array.from({ length: 30 }, (_: unknown, index: number): OpsDay => ({ day: dayOf(nowMs, index - 29), refusal: 0, providerError: 0, serverError: 0 })),
    });
    expect(product.economics.rates).toEqual({
      llmInputUsdPerMTok: 0.1,
      llmOutputUsdPerMTok: 0.5,
      elevenLabsUsdPerHour: 0.22,
      deepgramUsdPerMinute: 0.0092,
      priceUsdMonthly: 5.99,
      priceUsdYearly: 49,
    });
    expect(product.economics.months).toEqual([emptyMonth("2026-08", false, 0, 0), emptyMonth("2026-09", false, 0, 0), emptyMonth("2026-10", true, 0, 0)]);
    expect(product.economics.dailySpend).toEqual(Array.from({ length: 30 }, (_: unknown, index: number) => ({ day: dayOf(nowMs, index - 29), usd: 0, trialUsd: 0 })));
    expect(product.crashes).toEqual({ total: 0, recentDays: 30, versions: [] });
  });

  it("kohortlar, etkinlik, tutunma, ilk adımlar, deneme sonuçları, yarım Checkout, güvenilirlik, birim ekonomisi ve sürüme göre çökmeler", async () => {
    const harness: Harness = await defaultHarness();
    const nowMs: number = harness.clock.nowMs;
    const admin: Session = await signInWithGoogle(harness, adminSubject);

    // Hesaplar (önceki testin iki hesabı bu haftanın kohortunda kalır):
    // - A: 20 gün önce; iki deneme toplantısı (0. ve 1. hafta), denemesinin süresi doldu.
    // - B: 40 gün önce; deneme toplantısı (0. hafta) ve 31. günde abonelik toplantısı; aylık abone (ödeyen).
    // - C: 3 gün önce; toplantısız, Checkout'a gidip ödemedi.
    // - D: 100 gün önce; silinmiş hesabından devralınan 3 deneme toplantısıyla denemesi tükendi.
    // - E: dün; deneme sürüyor (biri bitirilmeden süresi dolmuş, biri açık iki toplantı).
    const a: number = nowMs - 20 * dayMs;
    const b: number = nowMs - 40 * dayMs;
    const e: number = nowMs - dayMs - hourMs;
    const userA: string = await insertUser(a);
    const userB: string = await insertUser(b);
    const userC: string = await insertUser(nowMs - 3 * dayMs);
    const userD: string = await insertUser(nowMs - 100 * dayMs);
    const userE: string = await insertUser(e);
    await grantSubscription(userB, "active", nowMs + 20 * dayMs);
    const [m1, m2, m3, m4, m5, m6] = [randomId(), randomId(), randomId(), randomId(), randomId(), randomId()];
    await env.DB.batch([
      env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(a + hourMs, userA),
      env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(b + 2 * hourMs, userB),
      env.DB.prepare("UPDATE users SET trial_started_at = ?, carried_trial_meetings = 3 WHERE id = ?").bind(nowMs - 100 * dayMs, userD),
      env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(nowMs - dayMs, userE),
      env.DB.prepare("INSERT INTO stripe_customers (user_id, stripe_customer_id, created_at) VALUES (?, 'cus_abandoned', ?)").bind(userC, nowMs - 2 * dayMs),
      // M1: A'nın ilki, 30 dk, not bitişten 120 sn sonra. M2: A'nın 8. gündeki toplantısı, 60 dk, iki hatalı istek, not yok.
      env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, ended_at, end_reason, token_budget, tokens_used, first_note_at,
           failure_count, last_failure_code)
         VALUES (?1, ?2, 'trial', ?3, ?4, ?5, 'ended', 1000, 100, ?6, 0, NULL),
                (?7, ?2, 'trial', ?8, ?9, ?10, 'ended', 1000, 0, NULL, 2, 'upstream_rejected:elevenlabs')`,
      ).bind(
        m1,
        userA,
        a + hourMs,
        a + hourMs + 90 * minuteMs,
        a + hourMs + 30 * minuteMs,
        a + hourMs + 30 * minuteMs + 120_000,
        m2,
        a + 8 * dayMs,
        a + 8 * dayMs + 90 * minuteMs,
        a + 8 * dayMs + 60 * minuteMs,
      ),
      // M3: B'nin ilki (güvenilirlik penceresi dışında), 30 dk, not 60 sn sonra. M4: B'nin 31. gündeki aboneliği, 60 dk,
      // yenisiyle kapandı, yapay zekâ bütçesi doldu.
      env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, ended_at, end_reason, token_budget, tokens_used, first_note_at)
         VALUES (?1, ?2, 'trial', ?3, ?4, ?5, 'ended', 1000, 0, ?6),
                (?7, ?2, 'subscription', ?8, ?9, ?10, 'superseded', 500, 500, NULL)`,
      ).bind(
        m3,
        userB,
        b + 2 * hourMs,
        b + 2 * hourMs + 90 * minuteMs,
        b + 2 * hourMs + 30 * minuteMs,
        b + 2 * hourMs + 30 * minuteMs + 60_000,
        m4,
        b + 31 * dayMs,
        b + 31 * dayMs + 240 * minuteMs,
        b + 31 * dayMs + 60 * minuteMs,
      ),
      // M5: E'nin dünkü toplantısı, bitirilmeden 90 dk'da süresi doldu. M6: şu an açık (10 dk), son hatası bütçe.
      env.DB.prepare(
        `INSERT INTO meeting_sessions (id, user_id, kind, started_at, max_ends_at, ended_at, token_budget, failure_count, last_failure_code)
         VALUES (?1, ?2, 'trial', ?3, ?4, NULL, 1000, 0, NULL), (?5, ?2, 'trial', ?6, ?7, NULL, 1000, 1, 'meeting_budget_exhausted')`,
      ).bind(m5, userE, nowMs - dayMs, nowMs - dayMs + 90 * minuteMs, m6, nowMs - 10 * minuteMs, nowMs + 80 * minuteMs),
      // Deepgram: M4 iki kez yeniden bağlandı (5 jeton, 2 akış × 60 dk); M5 yeniden bağlanmadı (3 jeton).
      env.DB.prepare(
        `INSERT INTO deepgram_live_meetings (meeting_id, grants, first_grant_at, charged_seconds, settled_at)
         VALUES (?1, 5, ?2, 7200, ?3), (?4, 3, ?5, 600, ?6)`,
      ).bind(m4, b + 31 * dayMs, nowMs, m5, nowMs - dayMs, nowMs),
      env.DB.prepare(
        `INSERT INTO ops_events (day, kind, detail, count) VALUES
           (?1, 'refusal', 'trial_capacity_reached', 2), (?1, 'server_error', 'internal_error', 1), (?2, 'provider_error', 'elevenlabs', 3),
           (?3, 'refusal', 'trial_capacity_reached', 9)`,
      ).bind(dayOf(nowMs, 0), dayOf(nowMs, -5), dayOf(nowMs, -40)),
      // Aylık kullanım: Ekim'de B (toplantı dışı 100K token dahil) ve E; Eylül'de A.
      env.DB.prepare(
        `INSERT INTO monthly_usage (user_id, month, input_tokens, output_tokens, account_tokens, audio_seconds) VALUES
           (?1, '2026-10', 1000000, 200000, 100000, 3600), (?2, '2026-10', 500000, 100000, 0, 1800), (?3, '2026-09', 200000, 20000, 0, 1800)`,
      ).bind(userB, userE, userA),
      env.DB.prepare(
        "INSERT INTO daily_spend (day, micro_usd, trial_micro_usd) VALUES (?1, 1500000, 400000), (?2, 200000, 200000), (?3, 9, 9)",
      ).bind(dayOf(nowMs, 0), dayOf(nowMs, -3), dayOf(nowMs, -40)),
      env.DB.prepare(
        `INSERT INTO reports (id, kind, status, created_at, app_version, summary) VALUES
           (?1, 'crash', 'open', ?2, '0.1.8', 'a'), (?3, 'crash', 'done', ?4, '0.1.8', 'b'), (?5, 'crash', 'open', ?6, '0.1.9', 'c'),
           (?7, 'crash', 'open', ?8, NULL, 'd'), (?9, 'feedback', 'open', ?6, '0.1.9', 'e')`,
      ).bind(randomId(), nowMs - dayMs, randomId(), nowMs - 50 * dayMs, randomId(), nowMs - 2 * hourMs, randomId(), nowMs - 100 * dayMs, randomId()),
    ]);

    const product: AdminProduct = await fetchProduct(harness, admin);

    // Etkinlik: son 7 günde yalnızca E; son 30 günde A, B ve E. Hafta 7'de E'nin iki toplantısı.
    expect(product.engagement.activeLast7Days).toBe(1);
    expect(product.engagement.activeLast30Days).toBe(3);
    expect(product.engagement.weeks.map((week) => [week.activeUsers, week.meetings, week.meetingsPerActiveUser])).toEqual([
      [0, 0, null],
      [1, 1, 1],
      [0, 0, null],
      [0, 0, null],
      [1, 1, 1],
      [1, 1, 1],
      [1, 1, 1],
      [1, 2, 2],
    ]);

    // Kohortlar: B (31 Ağustos haftası) 0. ve 4. haftada; A (21 Eylül haftası) 0. ve 1. haftada; bu hafta 4 kayıt, E 0. haftada.
    expect(product.cohorts).toEqual([
      { weekStart: "2026-08-24", signups: 0, activeByWeek: [0, 0, 0, 0, 0] },
      { weekStart: "2026-08-31", signups: 1, activeByWeek: [1, 0, 0, 0, 1] },
      { weekStart: "2026-09-07", signups: 0, activeByWeek: [0, 0, 0, 0, 0] },
      { weekStart: "2026-09-14", signups: 0, activeByWeek: [0, 0, 0, 0, 0] },
      { weekStart: "2026-09-21", signups: 1, activeByWeek: [1, 1, 0, 0, null] },
      { weekStart: "2026-09-28", signups: 0, activeByWeek: [0, 0, 0, null, null] },
      { weekStart: "2026-10-05", signups: 0, activeByWeek: [0, 0, null, null, null] },
      { weekStart: "2026-10-12", signups: 4, activeByWeek: [1, null, null, null, null] },
    ]);

    // D7: A, B, D uygun, A döndü. D30: B, D uygun, B döndü.
    expect(product.retention).toEqual({ d7: { day: 7, eligible: 3, retained: 1 }, d30: { day: 30, eligible: 2, retained: 1 } });

    // İlk adımlar (D 90 günden eski): toplantıya A 1 sa, B 2 sa, E 1 sa; nota A 1.920 sn, B 1.860 sn sonra.
    expect(product.timeToStep).toEqual({
      days: 90,
      signupToFirstMeeting: { users: 3, medianSeconds: 3600 },
      firstMeetingToFirstNote: { users: 2, medianSeconds: 1890 },
      signupToFirstNote: { users: 2, medianSeconds: 7290 },
    });
    expect(product.trialOutcomes).toEqual({ started: 4, converted: 1, exhausted: 1, expired: 1, active: 1 });
    expect(product.checkout).toEqual({ started: 2, paid: 1, abandoned: 1, startedLast30Days: 1, abandonedLast30Days: 1 });

    // Güvenilirlik (M3 pencere dışında): M1, M2, M4, M5, M6.
    expect(product.reliability).toMatchObject({
      days: 30,
      meetings: 5,
      failedMeetings: 2,
      failuresByCode: [
        { detail: "meeting_budget_exhausted", count: 1 },
        { detail: "upstream_rejected:elevenlabs", count: 1 },
      ],
      endedMeetings: 3,
      notedMeetings: 1,
      medianNoteSeconds: 120,
      superseded: 1,
      unended: 1,
      open: 1,
      budgetExhausted: 2,
      deepgram: { meetings: 2, baselineGrants: 3, grants: 8, withReconnects: 1, reconnects: 2 },
      onDevice: 3,
    });
    expect(product.reliability.opsDays).toHaveLength(30);
    expect(product.reliability.opsDays[29]).toEqual({ day: dayOf(nowMs, 0), refusal: 2, providerError: 0, serverError: 1 });
    expect(product.reliability.opsDays[24]).toEqual({ day: dayOf(nowMs, -5), refusal: 0, providerError: 3, serverError: 0 });

    // Birim ekonomisi. Ekim: 4 toplantı, 220 dk; yapay zekâ 0,30 $ (1/18'i toplantı dışı), ElevenLabs 1,5 sa × 0,22 $,
    // Deepgram 130 dk × 0,0092 $. Ödeyen B: 0,20 + 0,22 + 1,104 = 1,524 $ / 5,99 $.
    expect(product.economics.months).toEqual([
      emptyMonth("2026-08", false, 1, 5.99),
      {
        month: "2026-09",
        partial: false,
        meetings: 2,
        meetingHours: 1,
        meetingCostUsd: { llm: 0.03, elevenLabs: 0.11, deepgram: 0, total: 0.14 },
        accountLlmUsd: 0,
        perMeeting: { llm: 0.015, elevenLabs: 0.055, deepgram: 0, total: 0.07 },
        perMeetingHour: { llm: 0.03, elevenLabs: 0.11, deepgram: 0, total: 0.14 },
        payers: { users: 1, costUsd: 0, costPerUserUsd: 0, listRevenueUsd: 5.99, grossMarginPercent: 100 },
      },
      {
        month: "2026-10",
        partial: true,
        meetings: 4,
        meetingHours: 3.67,
        meetingCostUsd: { llm: 0.2833, elevenLabs: 0.33, deepgram: 1.196, total: 1.8093 },
        accountLlmUsd: 0.0167,
        perMeeting: { llm: 0.0708, elevenLabs: 0.0825, deepgram: 0.299, total: 0.4523 },
        perMeetingHour: { llm: 0.0773, elevenLabs: 0.09, deepgram: 0.3262, total: 0.4935 },
        payers: { users: 1, costUsd: 1.524, costPerUserUsd: 1.524, listRevenueUsd: 5.99, grossMarginPercent: 74.56 },
      },
    ]);
    expect(product.economics.dailySpend).toHaveLength(30);
    expect(product.economics.dailySpend[29]).toEqual({ day: dayOf(nowMs, 0), usd: 1.5, trialUsd: 0.4 });
    expect(product.economics.dailySpend[26]).toEqual({ day: dayOf(nowMs, -3), usd: 0.2, trialUsd: 0.2 });

    // Çökmeler: geri bildirim sayılmaz; eşit sayıda sonuncusu yeni olan önce.
    expect(product.crashes).toEqual({
      total: 4,
      recentDays: 30,
      versions: [
        { version: "0.1.8", total: 2, recent: 1, lastAt: iso(nowMs - dayMs) },
        { version: "0.1.9", total: 1, recent: 1, lastAt: iso(nowMs - 2 * hourMs) },
        { version: "", total: 1, recent: 0, lastAt: iso(nowMs - 100 * dayMs) },
      ],
    });
    // Yanıtta hesap kimliği yoktur.
    const text: string = JSON.stringify(product);
    for (const id of [userA, userB, userC, userD, userE, admin.userId]) {
      expect(text).not.toContain(id);
    }
  });
});

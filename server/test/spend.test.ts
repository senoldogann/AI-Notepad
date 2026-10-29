import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import {
  type UsageReservation,
  audioReservation,
  llmReservation,
  meetingAudioLimit,
  meetingTokenLimit,
  reserveUsage,
  settleAudioStatements,
  settleLLMStatements,
} from "../src/reservations";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  expectError,
  grantSubscription,
  req,
  signIn,
  startMeeting,
} from "./helpers";
import { stubStripeApi } from "./stripeFake";

/** 1000 girdi + 1000 çıktı tokenlık (600 mikro dolar) Haiku yanıtı. */
function stubHaiku(harness: Harness): void {
  harness.stub("https://api.anthropic.com/v1/messages", async (): Promise<Response> =>
    Response.json({
      id: "msg_1",
      type: "message",
      role: "assistant",
      model: "claude-haiku-5-5",
      content: [{ type: "text", text: "ok" }],
      stop_reason: "end_turn",
      stop_sequence: null,
      usage: { input_tokens: 1000, output_tokens: 1000, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    }),
  );
}

/** Yapay zekâ çağrısı; `meetingId` null ise toplantı dışı (hesap) çağrısıdır. */
function llmCall(harness: Harness, session: Session, meetingId: string | null): Promise<Response> {
  const headers: Record<string, string> = meetingId === null ? {} : { "x-meeting-id": meetingId };
  return harness.call(
    req("POST", "/v1/llm/messages", {
      token: session.accessToken,
      headers,
      json: { effort: "low", max_tokens: 2000, messages: [{ role: "user", content: "x" }] },
    }),
  );
}

// Bu dosyanın D1'i yalnızca kendine aittir: günlük harcama tablosu diğer testleri etkilemez.
describe("günlük harcama tavanı", () => {
  it("LLM kullanımı tahmini harcamaya eklenir; tavan aşılınca yeni toplantı 503 ile reddedilir ve alarm logu yazılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    stubHaiku(harness);
    expect((await llmCall(harness, session, meeting.meetingId)).status).toBe(200);
    const day: string = new Date(harness.clock.nowMs).toISOString().slice(0, 10);
    const spent = await env.DB.prepare("SELECT micro_usd FROM daily_spend WHERE day = ?").bind(day).first<{ micro_usd: number }>();
    // 1000 × 0,10 $/M + 1000 × 0,50 $/M = 600 mikro dolar.
    expect(spent?.micro_usd).toBe(600);

    // Tavan 25 $: günü tavana getir.
    await env.DB.prepare("UPDATE daily_spend SET micro_usd = ? WHERE day = ?").bind(25_000_000, day).run();
    const alerts = vi.spyOn(console, "error");
    const refused: Response = await startMeeting(harness, session);
    const body = await expectError(refused, 503, "spend_ceiling_reached");
    expect(body.error.message).toContain("daha sonra");
    expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"daily_spend_ceiling_reached"'))).toBe(true);
    alerts.mockRestore();

    // Tavan her vekil çağrısında da denetlenir: süren toplantı da durur.
    await expectError(await llmCall(harness, session, meeting.meetingId), 503, "spend_ceiling_reached");
    const audio: Uint8Array = new Uint8Array(1000);
    await expectError(
      await harness.call(
        req("POST", "/v1/transcribe", {
          token: session.accessToken,
          headers: { "x-meeting-id": meeting.meetingId, "content-type": "audio/mp4", "content-length": String(audio.byteLength) },
          body: audio,
        }),
      ),
      503,
      "spend_ceiling_reached",
    );

    // Ertesi gün tavan sıfırlanır.
    harness.clock.nowMs += 86_400_000;
    const fresh: Session = await signIn(harness);
    expect((await startMeeting(harness, fresh)).status).toBe(201);
  });
});

describe("günlük deneme harcaması tavanı", () => {
  it("deneme harcaması ayrı sayılır; tavanda deneme harcaması açan her yol 503 (yeni, açık ve yeniden işlenen deneme toplantısı, hesap çağrısı), aboneler sürer", async () => {
    const harness: Harness = await defaultHarness();
    // Üstteki test bugünün genel tavanını doldurdu: iki gün sonrası temizdir.
    harness.clock.nowMs += 2 * 86_400_000;
    stubHaiku(harness);
    const day: string = new Date(harness.clock.nowMs).toISOString().slice(0, 10);
    const spend = async (): Promise<{ micro_usd: number; trial_micro_usd: number } | null> =>
      env.DB.prepare("SELECT micro_usd, trial_micro_usd FROM daily_spend WHERE day = ?").bind(day).first<{ micro_usd: number; trial_micro_usd: number }>();

    const trial: Session = await signIn(harness);
    const trialMeeting: StartedMeetingBody = await (await startMeeting(harness, trial)).json<StartedMeetingBody>();
    expect((await llmCall(harness, trial, trialMeeting.meetingId)).status).toBe(200);
    expect((await llmCall(harness, trial, null)).status).toBe(200);
    expect(await spend()).toEqual({ micro_usd: 1200, trial_micro_usd: 1200 });

    const subscriber: Session = await signIn(harness);
    await grantSubscription(subscriber.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const paidMeeting: StartedMeetingBody = await (await startMeeting(harness, subscriber)).json<StartedMeetingBody>();
    expect((await llmCall(harness, subscriber, paidMeeting.meetingId)).status).toBe(200);
    expect(await spend()).toEqual({ micro_usd: 1800, trial_micro_usd: 1200 });

    // Deneme tavanı (10 $) doldu; genel tavan (25 $) dolmadı.
    await env.DB.prepare("UPDATE daily_spend SET trial_micro_usd = ? WHERE day = ?").bind(10_000_000, day).run();
    const alerts = vi.spyOn(console, "error");
    const alertCount = (): number =>
      alerts.mock.calls.filter((call: unknown[]): boolean => String(call[0]).includes('"event":"daily_trial_spend_ceiling_reached"')).length;
    const refused = await expectError(await startMeeting(harness, await signIn(harness)), 503, "trial_capacity_reached");
    expect(refused.error.message).toContain("abone ol");
    expect(alertCount()).toBe(1);
    await expectError(await llmCall(harness, trial, null), 503, "trial_capacity_reached");
    // Açık deneme toplantısı da tavandan sonra yeni deneme harcaması açamaz (yapay zekâ ve yazıya dökme).
    await expectError(await llmCall(harness, trial, trialMeeting.meetingId), 503, "trial_capacity_reached");
    const audio: Uint8Array = new Uint8Array(1000);
    await expectError(
      await harness.call(
        req("POST", "/v1/transcribe", {
          token: trial.accessToken,
          headers: { "x-meeting-id": trialMeeting.meetingId, "content-type": "audio/wav", "content-length": String(audio.byteLength) },
          body: audio,
        }),
      ),
      503,
      "trial_capacity_reached",
    );
    // Bitmiş deneme toplantısını yeniden işlemek de deneme harcaması açar: hak harcanmadan 503.
    await env.DB.prepare("UPDATE meeting_sessions SET ended_at = ?, end_reason = 'ended' WHERE id = ?")
      .bind(harness.clock.nowMs - 2 * 3_600_000, trialMeeting.meetingId)
      .run();
    await expectError(
      await harness.call(req("POST", `/v1/meetings/${trialMeeting.meetingId}/reprocess`, { token: trial.accessToken })),
      503,
      "trial_capacity_reached",
    );
    const reprocessed = await env.DB.prepare("SELECT reprocess_count FROM meeting_sessions WHERE id = ?").bind(trialMeeting.meetingId).first<{ reprocess_count: number }>();
    expect(reprocessed?.reprocess_count).toBe(0);
    // Alarm günde bir kez yazılır; retler "Sorunlar" sayacında ve toplantının son hatasında görünür.
    expect(alertCount()).toBe(1);
    alerts.mockRestore();
    await harness.drain();
    const counted = await env.DB.prepare("SELECT count FROM ops_events WHERE day = ? AND kind = 'refusal' AND detail = 'trial_capacity_reached'")
      .bind(day)
      .first<{ count: number }>();
    expect(counted?.count).toBe(5);
    const failure = await env.DB.prepare("SELECT failure_count, last_failure_code FROM meeting_sessions WHERE id = ?")
      .bind(trialMeeting.meetingId)
      .first<{ failure_count: number; last_failure_code: string }>();
    expect(failure).toEqual({ failure_count: 3, last_failure_code: "trial_capacity_reached" });
    // Aboneler yalnızca genel tavana tabidir.
    expect((await startMeeting(harness, subscriber)).status).toBe(201);
    expect((await llmCall(harness, subscriber, null)).status).toBe(200);
  });
});

describe("hesap silinirken süren çağrı", () => {
  it("kesinleştirme yabancı anahtar hatası almaz; harcama silmede tahminle bir kez yazılır", async () => {
    const harness: Harness = await defaultHarness();
    // Önceki testler bugünün harcama tavanını doldurdu: yeni gün.
    harness.clock.nowMs += 3 * 86_400_000;
    stubStripeApi(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const started: Response = await startMeeting(harness, session);
    expect(started.status).toBe(201);
    const meeting: StartedMeetingBody = await started.json<StartedMeetingBody>();
    const now: Date = new Date(harness.clock.nowMs);
    const llm: UsageReservation = llmReservation(
      { userId: session.userId, meetingId: meeting.meetingId, tokens: 100, trialAccountCall: false, subscriberAccountCall: false, estimatedMicroUsd: 700, trialSpend: false },
      now,
    );
    const audio: UsageReservation = audioReservation(session.userId, meeting.meetingId, 10, 300, false, now);
    await reserveUsage(env.DB, llm, [{ limit: meetingTokenLimit(meeting.meetingId, now), amount: 100 }]);
    await reserveUsage(env.DB, audio, [{ limit: meetingAudioLimit(meeting.meetingId), amount: 10 }]);
    const day: string = now.toISOString().slice(0, 10);
    const spend = async (): Promise<{ micro_usd: number; audio_seconds: number }> =>
      (await env.DB.prepare("SELECT micro_usd, audio_seconds FROM daily_spend WHERE day = ?").bind(day).first<{ micro_usd: number; audio_seconds: number }>()) ?? {
        micro_usd: 0,
        audio_seconds: 0,
      };
    const before = await spend();
    expect((await harness.call(req("DELETE", "/v1/me", { token: session.accessToken }))).status).toBe(204);
    // Silme, süren ayırmaların tahminini yazar.
    expect(await spend()).toEqual({ micro_usd: before.micro_usd + 1000, audio_seconds: before.audio_seconds + 10 });
    // Üst servis yanıtı sonra gelir: kesinleştirme hata vermez, ikinci kez yazmaz, silinmiş hesaba sayaç açmaz.
    await env.DB.batch(settleLLMStatements(env.DB, llm, { inputTokens: 50, outputTokens: 50 }, 600, now));
    await env.DB.batch(settleAudioStatements(env.DB, audio, 10, false, 300, 10, now));
    expect(await spend()).toEqual({ micro_usd: before.micro_usd + 1000, audio_seconds: before.audio_seconds + 10 });
    const counters = await env.DB.prepare(
      "SELECT (SELECT COUNT(*) FROM monthly_usage WHERE user_id = ?1) + (SELECT COUNT(*) FROM daily_usage WHERE user_id = ?1) AS count",
    )
      .bind(session.userId)
      .first<{ count: number }>();
    expect(counters?.count).toBe(0);
  });
});

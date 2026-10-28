import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  envWith,
  expectError,
  grantSubscription,
  req,
  signIn,
  startMeeting,
} from "./helpers";

const anthropicUrl: string = "https://api.anthropic.com/v1/messages";

interface Context {
  readonly harness: Harness;
  readonly session: Session;
  readonly meeting: StartedMeetingBody;
}

async function setup(): Promise<Context> {
  const harness: Harness = await defaultHarness();
  const session: Session = await signIn(harness);
  const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
  return { harness, session, meeting };
}

function llm(context: Context, json: object, environment: Env | null): Promise<Response> {
  return context.harness.call(
    req("POST", "/v1/llm/messages", { token: context.session.accessToken, headers: { "x-meeting-id": context.meeting.meetingId }, json, env: environment }),
  );
}

function message(inputTokens: number, outputTokens: number): object {
  return {
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content: [{ type: "text", text: "Merhaba" }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: inputTokens, output_tokens: outputTokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
  };
}

function sse(events: ReadonlyArray<readonly [string, object]>): string {
  return events.map(([type, data]): string => `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`).join("");
}

const streamEvents: ReadonlyArray<readonly [string, object]> = [
  ["message_start", { type: "message_start", message: { ...message(200, 1), content: [], stop_reason: null } }],
  ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
  ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Mer" } }],
  ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "haba" } }],
  ["content_block_stop", { type: "content_block_stop", index: 0 }],
  ["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 40 } }],
  ["message_stop", { type: "message_stop" }],
];

async function meetingTokens(meetingId: string): Promise<number> {
  const row = await env.DB.prepare("SELECT tokens_used FROM meeting_sessions WHERE id = ?").bind(meetingId).first<{ tokens_used: number }>();
  return row?.tokens_used ?? -1;
}

const basic = { effort: "low", max_tokens: 1000, messages: [{ role: "user", content: "Bu toplantıyı özetle." }] };

describe("LLM vekili: izin listesi", () => {
  it.each([
    ["araçlar", { ...basic, tools: [{ name: "x", input_schema: { type: "object" } }] }],
    ["MCP", { ...basic, mcp_servers: [{ type: "url", url: "https://evil.example", name: "x" }] }],
    ["görsel", { ...basic, messages: [{ role: "user", content: [{ type: "image", source: { type: "url", url: "https://x" } }] }] }],
    ["dosya", { ...basic, messages: [{ role: "user", content: [{ type: "document", source: { type: "file", file_id: "f" } }] }] }],
    ["temperature", { ...basic, temperature: 0 }],
    ["thinking", { ...basic, thinking: { type: "enabled", budget_tokens: 2000 } }],
    ["önbellek işareti", { ...basic, messages: [{ role: "user", content: [{ type: "text", text: "x", cache_control: { type: "ephemeral" } }] }] }],
    ["bilinmeyen alan", { ...basic, metadata: { user_id: "x" } }],
    ["ön doldurma", { ...basic, messages: [{ role: "user", content: "x" }, { role: "assistant", content: "{" }] }],
    ["sistem rolü", { ...basic, messages: [{ role: "system", content: "x" }] }],
    ["metin dışı biçim", { ...basic, output_config: { format: { type: "text" } } }],
    ["effort eksik", { max_tokens: 1000, messages: [{ role: "user", content: "x" }] }],
    ["effort high", { ...basic, effort: "high" }],
    ["effort max", { ...basic, effort: "max" }],
    ["output_config.effort", { ...basic, output_config: { effort: "low" } }],
  ])("%s reddedilir ve dışarı istek gitmez", async (_name: string, body: object) => {
    const context: Context = await setup();
    const before: number = context.harness.outbound.length;
    await expectError(await llm(context, body, null), 400, "invalid_body");
    expect(context.harness.outbound.length).toBe(before);
  });

  it("geçersiz x-meeting-id reddedilir", async () => {
    const context: Context = await setup();
    await expectError(
      await context.harness.call(req("POST", "/v1/llm/messages", { token: context.session.accessToken, headers: { "x-meeting-id": "toplanti" }, json: basic })),
      400,
      "bad_request",
    );
  });

  it("bayt sınırını ve token tahmini sınırını aşan girdi reddedilir", async () => {
    const context: Context = await setup();
    const big = { ...basic, messages: [{ role: "user", content: "a".repeat(400_001) }] };
    await expectError(await llm(context, big, null), 413, "payload_too_large");
    const smallCap = envWith({ LLM_MAX_INPUT_TOKENS: "100" });
    const medium = { ...basic, messages: [{ role: "user", content: "a".repeat(600) }] };
    await expectError(await llm(context, medium, smallCap), 413, "payload_too_large");
  });
});

describe("LLM vekili: üst istek ve muhasebe", () => {
  it("model sabitlenir, max_tokens sınırlanır, effort istekten (low/medium) gider; kullanım sayılır", async () => {
    const context: Context = await setup();
    let upstream: Record<string, unknown> = {};
    let apiKey: string | null = null;
    context.harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      upstream = await request.json<Record<string, unknown>>();
      apiKey = request.headers.get("authorization");
      return Response.json(message(150, 50));
    });
    const schema = { type: "object", properties: { summary: { type: "string" } }, required: ["summary"], additionalProperties: false };
    const response: Response = await llm(
      context,
      {
        effort: "medium",
        model: "claude-opus-5-5",
        system: "Türkçe yaz.",
        max_tokens: 50_000,
        messages: [{ role: "user", content: [{ type: "text", text: "Özetle." }] }],
        output_config: { format: { type: "json_schema", schema } },
      },
      null,
    );
    expect(response.status).toBe(200);
    expect((await response.json<{ content: Array<{ text: string }> }>()).content[0]?.text).toBe("Merhaba");
    // SDK 1.x anahtarı Bearer olarak gönderir; istemcinin erişim jetonu üst servise gitmez.
    expect(apiKey).toBe(`Bearer ${env.ANTHROPIC_API_KEY}`);
    expect(upstream).toEqual({
      model: "claude-haiku-5-5",
      max_tokens: 8192,
      system: "Türkçe yaz.",
      messages: [{ role: "user", content: [{ type: "text", text: "Özetle." }] }],
      output_config: { effort: "medium", format: { type: "json_schema", schema } },
    });
    expect(await meetingTokens(context.meeting.meetingId)).toBe(200);
    const usage = await env.DB.prepare("SELECT input_tokens, output_tokens FROM monthly_usage WHERE user_id = ?")
      .bind(context.session.userId)
      .first<{ input_tokens: number; output_tokens: number }>();
    expect(usage).toEqual({ input_tokens: 150, output_tokens: 50 });
  });

  it("akış SSE olarak aktarılır ve bitince gerçek kullanım yazılır", async () => {
    const context: Context = await setup();
    let streamed: unknown = null;
    context.harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      streamed = (await request.json<{ stream: boolean }>()).stream;
      return new Response(sse(streamEvents), { headers: { "content-type": "text/event-stream" } });
    });
    const response: Response = await llm(context, { ...basic, stream: true }, null);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    const text: string = await response.text();
    await context.harness.drain();
    expect(streamed).toBe(true);
    expect(text).toContain('event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Mer"}}');
    expect(text).toContain("event: message_stop");
    expect(await meetingTokens(context.meeting.meetingId)).toBe(240);
  });

  it("akış ortasındaki hata istemciye error olayı olarak gider, ayrılan bütçe harcanmış sayılır", async () => {
    const context: Context = await setup();
    context.harness.stub(anthropicUrl, async (): Promise<Response> => {
      const partial: string = sse(streamEvents.slice(0, 3)) + `event: error\ndata: ${JSON.stringify({ type: "error", error: { type: "overloaded_error", message: "Overloaded" } })}\n\n`;
      return new Response(partial, { headers: { "content-type": "text/event-stream" } });
    });
    const response: Response = await llm(context, { ...basic, stream: true }, null);
    const text: string = await response.text();
    await context.harness.drain();
    expect(text).toContain("event: error");
    expect(text).not.toContain("Overloaded");
    // Girdi message_start'tan (200), çıktı ayrılan üst sınırdan (1000).
    expect(await meetingTokens(context.meeting.meetingId)).toBe(1200);
  });

  it("geçici hata (529) yeniden denenir; kalıcı hata (400) mesajı sızdırmadan 502 olur ve ayırma geri verilir", async () => {
    const context: Context = await setup();
    let calls: number = 0;
    context.harness.stub(anthropicUrl, async (): Promise<Response> => {
      calls += 1;
      return calls === 1
        ? Response.json({ type: "error", error: { type: "overloaded_error", message: "Overloaded" } }, { status: 529 })
        : Response.json(message(10, 5));
    });
    expect((await llm(context, basic, null)).status).toBe(200);
    expect(calls).toBe(2);

    context.harness.stub(anthropicUrl, async (): Promise<Response> =>
      Response.json({ type: "error", error: { type: "invalid_request_error", message: "gizli ayrıntı sk-ant-xxx" } }, { status: 400 }),
    );
    const before: number = await meetingTokens(context.meeting.meetingId);
    const body = await expectError(await llm(context, basic, null), 502, "upstream_rejected");
    expect(body.error.message).not.toContain("gizli");
    expect(await meetingTokens(context.meeting.meetingId)).toBe(before);

    let failures: number = 0;
    context.harness.stub(anthropicUrl, async (): Promise<Response> => {
      failures += 1;
      return new Response("{}", { status: 503 });
    });
    await expectError(await llm(context, basic, null), 502, "upstream_unavailable");
    expect(failures).toBe(3);
  });

  it("bütçe max_tokens'ı kısar, bitince istek reddedilir", async () => {
    const context: Context = await setup();
    let maxTokens: number = 0;
    context.harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      maxTokens = (await request.json<{ max_tokens: number }>()).max_tokens;
      return Response.json(message(10, 5));
    });
    await env.DB.prepare("UPDATE meeting_sessions SET tokens_used = token_budget - 3000 WHERE id = ?").bind(context.meeting.meetingId).run();
    expect((await llm(context, { ...basic, max_tokens: 8000 }, null)).status).toBe(200);
    expect(maxTokens).toBeLessThan(3000);
    expect(maxTokens).toBeGreaterThanOrEqual(1024);

    await env.DB.prepare("UPDATE meeting_sessions SET tokens_used = token_budget - 500 WHERE id = ?").bind(context.meeting.meetingId).run();
    await expectError(await llm(context, basic, null), 429, "meeting_budget_exhausted");
  });
});

describe("LLM vekili: toplantısız (hesap) çağrılar", () => {
  /** Toplantı kimliği olmadan çağrı. */
  function accountLLM(harness: Harness, session: Session, json: object, environment: Env | null): Promise<Response> {
    return harness.call(req("POST", "/v1/llm/messages", { token: session.accessToken, json, env: environment }));
  }

  /** Kullanıcının deneme toplantılarını harcar (başlatır, hemen sonrakine geçer). */
  async function useAllTrials(harness: Harness, session: Session): Promise<void> {
    for (let index: number = 0; index < Number(env.TRIAL_MEETINGS); index += 1) {
      expect((await startMeeting(harness, session)).status).toBe(201);
    }
  }

  async function userTokens(userId: string): Promise<{ monthly: number; daily: number }> {
    const monthly = await env.DB.prepare("SELECT input_tokens + output_tokens AS used FROM monthly_usage WHERE user_id = ?").bind(userId).first<{ used: number }>();
    const daily = await env.DB.prepare("SELECT tokens_used AS used FROM daily_usage WHERE user_id = ?").bind(userId).first<{ used: number }>();
    return { monthly: monthly?.used ?? 0, daily: daily?.used ?? 0 };
  }

  it("denemesi kalan yeni hesap toplantısız çağırabilir; max_tokens küçük sınırla kısılır, kullanıcı sınırına sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    let maxTokens: number = 0;
    harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      maxTokens = (await request.json<{ max_tokens: number }>()).max_tokens;
      return Response.json(message(120, 30));
    });
    const response: Response = await accountLLM(harness, session, { ...basic, effort: "medium", max_tokens: 16_000 }, null);
    expect(response.status).toBe(200);
    expect(maxTokens).toBe(Number(env.LLM_ACCOUNT_MAX_TOKENS));
    expect(maxTokens).toBeLessThan(Number(env.LLM_MAX_TOKENS));
    expect(await userTokens(session.userId)).toEqual({ monthly: 150, daily: 150 });
    // Hiçbir toplantı açılmadı ve deneme hakkı düşmedi.
    const meetings = await env.DB.prepare("SELECT COUNT(*) AS count FROM meeting_sessions WHERE user_id = ?").bind(session.userId).first<{ count: number }>();
    expect(meetings?.count).toBe(0);
  });

  it("akışlı toplantısız çağrı aktarılır ve kullanıcıya sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    harness.stub(anthropicUrl, async (): Promise<Response> => new Response(sse(streamEvents), { headers: { "content-type": "text/event-stream" } }));
    const response: Response = await accountLLM(harness, session, { ...basic, stream: true }, null);
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("event: message_stop");
    await harness.drain();
    expect(await userTokens(session.userId)).toEqual({ monthly: 240, daily: 240 });
  });

  it("denemesi bitmiş ve aboneliği olmayan hesap reddedilir, dışarı istek gitmez", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await useAllTrials(harness, session);
    const before: number = harness.outbound.length;
    await expectError(await accountLLM(harness, session, basic, null), 402, "subscription_required");
    expect(harness.outbound.length).toBe(before);
  });

  it("denemesi bitmiş abone (ek süre dahil) çağırabilir; erişimi bitmiş abonelik reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    harness.stub(anthropicUrl, async (): Promise<Response> => Response.json(message(10, 5)));
    const active: Session = await signIn(harness);
    await useAllTrials(harness, active);
    await grantSubscription(active.userId, "active", harness.clock.nowMs + 86_400_000);
    expect((await accountLLM(harness, active, basic, null)).status).toBe(200);

    const pastDue: Session = await signIn(harness);
    await useAllTrials(harness, pastDue);
    await grantSubscription(pastDue.userId, "past_due", harness.clock.nowMs - 86_400_000);
    expect((await accountLLM(harness, pastDue, basic, null)).status).toBe(200);

    const canceled: Session = await signIn(harness);
    await useAllTrials(harness, canceled);
    await grantSubscription(canceled.userId, "canceled", harness.clock.nowMs + 86_400_000);
    await expectError(await accountLLM(harness, canceled, basic, null), 402, "subscription_required");
  });

  it("günlük ve aylık token sınırı ve harcama tavanı toplantısız çağrıda da geçerli", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    harness.stub(anthropicUrl, async (): Promise<Response> => Response.json(message(10, 5)));
    await expectError(await accountLLM(harness, session, basic, envWith({ DAILY_TOKEN_CAP: "500" })), 429, "daily_cap_reached");
    await expectError(await accountLLM(harness, session, basic, envWith({ MONTHLY_TOKEN_CAP: "500" })), 403, "monthly_cap_reached");
    await expectError(await accountLLM(harness, session, basic, envWith({ DAILY_SPEND_CEILING_USD: "0.000001" })), 503, "spend_ceiling_reached");
    expect(await userTokens(session.userId)).toEqual({ monthly: 0, daily: 0 });
  });

  it("toplantıya bağlı çağrı değişmeden toplantı bütçesinden düşer", async () => {
    const context: Context = await setup();
    context.harness.stub(anthropicUrl, async (): Promise<Response> => Response.json(message(10, 5)));
    expect((await llm(context, basic, null)).status).toBe(200);
    expect(await meetingTokens(context.meeting.meetingId)).toBe(15);
  });
});

import { describe, expect, it, vi } from "vitest";
import { runAfterResponse } from "../src/background";
import type { RequestContext } from "../src/platform";
import { type Harness, type Session, type StartedMeetingBody, defaultHarness, req, signIn, startMeeting } from "./helpers";

describe("log hijyeni", () => {
  it("loglar yapılandırılmış JSON'dur; jeton, anahtar ve toplantı içeriği içermez", async () => {
    const lines: string[] = [];
    const capture = (...args: unknown[]): void => {
      lines.push(args.map((arg: unknown): string => String(arg)).join(" "));
    };
    const spies = [vi.spyOn(console, "log").mockImplementation(capture), vi.spyOn(console, "warn").mockImplementation(capture), vi.spyOn(console, "error").mockImplementation(capture)];
    try {
      const harness: Harness = await defaultHarness();
      const secretContent: string = "GİZLİ-TOPLANTI-İÇERİĞİ-42";
      harness.stub("https://api.anthropic.com/v1/messages", async (): Promise<Response> =>
        Response.json({ type: "error", error: { type: "invalid_request_error", message: `bad: ${secretContent}` } }, { status: 400 }),
      );
      const session: Session = await signIn(harness);
      const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
      await harness.call(
        req("POST", "/v1/llm/messages", {
          token: session.accessToken,
          headers: { "x-meeting-id": meeting.meetingId },
          json: { effort: "low", max_tokens: 1000, messages: [{ role: "user", content: secretContent }] },
        }),
      );
      await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }));
      // 30 saniyelik yeniden deneme süresinden sonra eski jeton yeniden kullanımdır.
      harness.clock.nowMs += 31_000;
      await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }));

      const ours: string[] = lines.filter((line: string): boolean => line.startsWith("{"));
      expect(ours.length).toBeGreaterThan(3);
      for (const line of ours) {
        const parsed: { level: string; event: string } = JSON.parse(line);
        expect(typeof parsed.event).toBe("string");
        expect(line).not.toContain(secretContent);
        expect(line).not.toContain(session.accessToken);
        expect(line).not.toContain(session.refreshToken);
        expect(line).not.toContain("test-anthropic-key");
      }
      expect(ours.some((line: string): boolean => line.includes('"event":"refresh_token_reuse"'))).toBe(true);
    } finally {
      for (const spy of spies) {
        spy.mockRestore();
      }
    }
  });
});

describe("yanıttan sonra süren iş", () => {
  it("akış kesinleştirmesi gibi yanıttan sonraki işin hatası kaybolmaz: alarm yazılır", async () => {
    const harness: Harness = await defaultHarness();
    const pending: Promise<void>[] = [];
    const context: RequestContext = { platform: harness.platform, clientIp: "local", waitUntil: (promise: Promise<void>): void => void pending.push(promise) };
    const alerts = vi.spyOn(console, "error");
    runAfterResponse(context, Promise.reject(new Error("D1 yazılamadı")), "llm_settle_failed", { reservationId: "r1" });
    await Promise.all(pending);
    const lines: string[] = alerts.mock.calls.map((call: unknown[]): string => String(call[0]));
    alerts.mockRestore();
    expect(lines.some((line: string): boolean => line.includes('"event":"llm_settle_failed"') && line.includes('"reservationId":"r1"'))).toBe(true);
  });
});

import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { appcastLatestVersion } from "../src/downloads";
import { type Harness, blockingLimiter, defaultHarness, envWith, expectError, req } from "./helpers";

const dmgUrl: string = "https://github.com/senoldogann/AI-Notepad/releases/latest/download/AI-Notepad.dmg";

async function counts(): Promise<Array<{ day: string; count: number }>> {
  return (await env.DB.prepare("SELECT day, count FROM downloads ORDER BY day").all<{ day: string; count: number }>()).results;
}

describe("GET /v1/download/mac", () => {
  it("DMG'ye 302 ile yönlendirir ve UTC gün başına sayar; başka bir şey saklamaz", async () => {
    const harness: Harness = await defaultHarness();
    for (let index: number = 0; index < 2; index += 1) {
      const response: Response = await harness.call(req("GET", "/v1/download/mac", { headers: { "user-agent": "Safari" } }));
      expect(response.status).toBe(302);
      expect(response.headers.get("location")).toBe(dmgUrl);
      expect(response.headers.get("cache-control")).toBe("no-store");
    }
    harness.clock.nowMs += 86_400_000;
    expect((await harness.call(req("GET", "/v1/download/mac", {}))).status).toBe(302);
    expect(await counts()).toEqual([
      { day: "2026-10-15", count: 2 },
      { day: "2026-10-16", count: 1 },
    ]);
    const columns = await env.DB.prepare("SELECT name FROM pragma_table_info('downloads') ORDER BY cid").all<{ name: string }>();
    expect(columns.results.map((column: { name: string }): string => column.name)).toEqual(["day", "count"]);
  });

  it("API IP hız sınırına tabidir", async () => {
    const harness: Harness = await defaultHarness();
    await expectError(await harness.call(req("GET", "/v1/download/mac", { env: envWith({ API_IP_LIMITER: blockingLimiter }) })), 429, "rate_limited");
  });

  it("sayaç yazılamazsa uyarı loglanır ve indirme yine yönlendirilir", async () => {
    const harness: Harness = await defaultHarness();
    await env.DB.prepare("DROP TABLE downloads").run();
    const warnings = vi.spyOn(console, "warn");
    const response: Response = await harness.call(req("GET", "/v1/download/mac", {}));
    const lines: string[] = warnings.mock.calls.map((call: unknown[]): string => String(call[0]));
    warnings.mockRestore();
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(dmgUrl);
    const line: string | undefined = lines.find((text: string): boolean => text.includes('"event":"download_count_failed"'));
    expect(JSON.parse(line ?? "{}")).toEqual({ level: "warn", event: "download_count_failed", error: "Error" });
  });
});

const appcastUrl: string = "https://github.com/senoldogann/AI-Notepad/releases/latest/download/appcast.xml";

/** İki sürümlü appcast (generate_appcast en yeniyi başa yazar). */
const appcast: string = `<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Gistsmith</title>
<item><title>0.1.5</title><sparkle:version>6</sparkle:version><sparkle:shortVersionString>0.1.5</sparkle:shortVersionString></item>
<item><title>0.1.4</title><sparkle:version>5</sparkle:version><sparkle:shortVersionString>0.1.4</sparkle:shortVersionString></item>
</channel></rss>`;

describe("GET /v1/download/mac/version", () => {
  it("DMG ile aynı sürümdeki appcast'ten en yeni sürümü döner; site kaynağına açık ve 5 dk önbelleklenir", async () => {
    const harness: Harness = await defaultHarness();
    harness.stub(appcastUrl, async (): Promise<Response> => new Response(appcast, { status: 200 }));
    const response: Response = await harness.call(req("GET", "/v1/download/mac/version", { headers: { origin: env.SITE_ORIGIN } }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ version: "0.1.5" });
    expect(response.headers.get("cache-control")).toBe("public, max-age=300");
    expect(response.headers.get("access-control-allow-origin")).toBe(env.SITE_ORIGIN);
  });

  it("akışta sürüm yoksa ya da akış okunamazsa 502 upstream_unavailable", async () => {
    const harness: Harness = await defaultHarness();
    harness.stub(appcastUrl, async (): Promise<Response> => new Response("<rss><channel></channel></rss>", { status: 200 }));
    await expectError(await harness.call(req("GET", "/v1/download/mac/version", {})), 502, "upstream_unavailable");
    harness.stub(appcastUrl, async (): Promise<Response> => new Response("yok", { status: 404 }));
    await expectError(await harness.call(req("GET", "/v1/download/mac/version", {})), 502, "upstream_unavailable");
  });
});

describe("appcastLatestVersion", () => {
  it("ilk öğenin görünen sürümünü alır; biçimsiz değeri kabul etmez", () => {
    expect(appcastLatestVersion(appcast)).toBe("0.1.5");
    expect(appcastLatestVersion("<item><sparkle:shortVersionString>0.1.4 <script></sparkle:shortVersionString></item>")).toBeNull();
    expect(appcastLatestVersion("<rss></rss>")).toBeNull();
  });
});

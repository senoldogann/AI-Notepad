import { describe, expect, it, vi } from "vitest";
import { type Config, ConfigPlaceholderError, parseConfig } from "../src/config";
import type { Env } from "../src/env";
import { type Harness, defaultHarness, envWith, expectError, req } from "./helpers";

/** `wrangler.jsonc` → `env.production.vars` içindeki yer tutucularla üretim ortamı. */
const productionWithPlaceholders: Env = envWith({
  ENVIRONMENT: "production",
  SITE_ORIGIN: "https://ainotepad.pages.dev",
  APP_ATTEST_ENVIRONMENT: "production",
  APP_ATTEST_APP_IDS: "TEAMID0000.com.senoldogan.AINotepad.hosted",
  EMAIL_SENDER: "resend",
  EMAIL_FROM: "AI-Notepad <giris@example.com>",
  EMAIL_LINK_URL: "https://ainotepad.pages.dev/giris/eposta",
  STRIPE_PRICE_ID: "price_placeholder",
});

/** Gerçek görünen değerlerle üretim ortamı. */
const productionFilledIn: Env = envWith({
  ...productionWithPlaceholders,
  APP_ATTEST_APP_IDS: "A1B2C3D4E5.com.senoldogan.AINotepad.hosted",
  EMAIL_FROM: "AI-Notepad <giris@ainotepad.app>",
  STRIPE_PRICE_ID: "price_1QabcDEFghiJKL",
});

function placeholderError(env: Env): ConfigPlaceholderError {
  try {
    parseConfig(env);
  } catch (error: unknown) {
    if (error instanceof ConfigPlaceholderError) {
      return error;
    }
    throw error;
  }
  throw new Error("yer tutucu reddedilmedi");
}

describe("üretim yapılandırmasında yer tutucular", () => {
  it("yer tutuculu üretim yapılandırması ayar adlarıyla (değerleri olmadan) reddedilir", () => {
    const error: ConfigPlaceholderError = placeholderError(productionWithPlaceholders);
    expect(error.fields).toEqual(["APP_ATTEST_APP_IDS", "EMAIL_FROM", "STRIPE_PRICE_ID"]);
    for (const value of ["TEAMID0000", "example.com", "price_placeholder"]) {
      expect(error.message).not.toContain(value);
    }
  });

  it("örnek ya da yerel adresler de yer tutucudur", () => {
    const local: Env = envWith({
      ...productionFilledIn,
      SITE_ORIGIN: "http://localhost:8788",
      EMAIL_LINK_URL: "https://www.example.org/giris",
    });
    expect(placeholderError(local).fields).toEqual(["SITE_ORIGIN", "EMAIL_LINK_URL"]);
  });

  it("doldurulmuş üretim yapılandırması ve yer tutuculu geliştirme yapılandırması kabul edilir", () => {
    const production: Config = parseConfig(productionFilledIn);
    expect(production.environment).toBe("production");
    expect(production.stripePriceId).toBe("price_1QabcDEFghiJKL");
    const development: Config = parseConfig(envWith({}));
    expect(development.environment).toBe("development");
    expect(development.stripePriceId).toBe("price_placeholder");
  });

  it("yer tutuculu üretim sunucusu her istekte (sağlık dahil) 500 verir ve yalnızca ayar adlarını loglar", async () => {
    const harness: Harness = await defaultHarness();
    const errors = vi.spyOn(console, "error");
    await expectError(await harness.call(req("GET", "/v1/health", { env: productionWithPlaceholders })), 500, "internal_error");
    const lines: string[] = errors.mock.calls.map((call: unknown[]): string => String(call[0]));
    errors.mockRestore();
    const line: string | undefined = lines.find((text: string): boolean => text.includes('"event":"config_invalid"'));
    expect(JSON.parse(line ?? "{}")).toEqual({
      level: "error",
      event: "config_invalid",
      error: "ConfigPlaceholderError",
      fields: "APP_ATTEST_APP_IDS,EMAIL_FROM,STRIPE_PRICE_ID",
    });
    expect((await harness.call(req("GET", "/v1/health", { env: productionFilledIn }))).status).toBe(200);
  });
});

import { describe, expect, it, vi } from "vitest";
import { type Config, ConfigError, ConfigPlaceholderError, parseConfig } from "../src/config";
import type { Env } from "../src/env";
import { type Harness, defaultHarness, envWith, expectError, req } from "./helpers";

/** Yer tutucularla (örnek ve `placeholder` değerler) üretim ortamı. */
const productionWithPlaceholders: Env = envWith({
  ENVIRONMENT: "production",
  SITE_ORIGIN: "https://gistsmith.com",
  APP_ATTEST_ENVIRONMENT: "production",
  APP_ATTEST_APP_IDS: "TEAMID0000.com.senoldogan.AINotepad.hosted",
  GOOGLE_CLIENT_IDS: "000000000000-placeholder.apps.googleusercontent.com",
  STRIPE_PRICE_ID: "price_placeholder",
});

/** Gerçek görünen değerlerle üretim ortamı. */
const productionFilledIn: Env = envWith({
  ...productionWithPlaceholders,
  APP_ATTEST_APP_IDS: "A1B2C3D4E5.com.senoldogan.AINotepad.hosted",
  GOOGLE_CLIENT_IDS: "123456789012-abc.apps.googleusercontent.com,123456789012-web.apps.googleusercontent.com",
  STRIPE_PRICE_ID: "price_1QabcDEFghiJKL",
  STRIPE_YEARLY_PRICE_ID: "price_1QyearDEFghiJKL",
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

function configErrorFields(env: Env): readonly string[] {
  try {
    parseConfig(env);
  } catch (error: unknown) {
    if (error instanceof ConfigError) {
      return error.fields;
    }
    throw error;
  }
  throw new Error("yapılandırma reddedilmedi");
}

describe("üretim yapılandırmasında yer tutucular", () => {
  it("yer tutuculu üretim yapılandırması ayar adlarıyla (değerleri olmadan) reddedilir", () => {
    const error: ConfigPlaceholderError = placeholderError(productionWithPlaceholders);
    expect(error.fields).toEqual(["APP_ATTEST_APP_IDS", "GOOGLE_CLIENT_IDS", "STRIPE_PRICE_ID", "STRIPE_YEARLY_PRICE_ID"]);
    for (const value of ["TEAMID0000", "000000000000-placeholder", "price_placeholder", "price_yearly_placeholder"]) {
      expect(error.message).not.toContain(value);
    }
  });

  it("örnek ya da yerel adresler de yer tutucudur", () => {
    const local: Env = envWith({
      ...productionFilledIn,
      SITE_ORIGIN: "http://localhost:8788",
      DMG_URL: "https://www.example.org/indir.dmg",
    });
    expect(placeholderError(local).fields).toEqual(["SITE_ORIGIN", "DMG_URL"]);
  });

  it("doldurulmuş üretim yapılandırması ve yer tutuculu geliştirme yapılandırması kabul edilir", () => {
    const production: Config = parseConfig(productionFilledIn);
    expect(production.environment).toBe("production");
    expect(production.stripePrices).toEqual({ monthly: "price_1QabcDEFghiJKL", yearly: "price_1QyearDEFghiJKL" });
    expect(production.priceUsdYearly).toBe(49);
    expect(production.googleClientIds).toHaveLength(2);
    expect(production.adminIdentities).toEqual([]);
    const development: Config = parseConfig(envWith({}));
    expect(development.environment).toBe("development");
    expect(development.stripePrices).toEqual({ monthly: "price_placeholder", yearly: "price_yearly_placeholder" });
    // Aynı fiyat iki plana verilemez (plan ve MRR ayırt edilemez).
    expect(configErrorFields(envWith({ STRIPE_YEARLY_PRICE_ID: "price_placeholder" }))).toEqual(["STRIPE_YEARLY_PRICE_ID"]);
  });

  it("yönetici kimlikleri `apple:` ya da `google:` önekli olmalı; DMG adresi https olmalı", () => {
    expect(parseConfig(envWith({ ADMIN_IDENTITIES: " google:123 , apple:000.abc " })).adminIdentities).toEqual(["google:123", "apple:000.abc"]);
    expect(configErrorFields(envWith({ ADMIN_IDENTITIES: "123" }))).toEqual(["ADMIN_IDENTITIES"]);
    expect(configErrorFields(envWith({ ADMIN_IDENTITIES: "email:kisi@ornek.test" }))).toEqual(["ADMIN_IDENTITIES"]);
    // Cloudflare Access: AUD boşsa denetim kapalı (null), değilse 64 onaltılık karakter.
    expect(parseConfig(envWith({})).access).toEqual({ teamDomain: "dry-heart-1ee2.cloudflareaccess.com", audience: null });
    expect(parseConfig(envWith({ CF_ACCESS_AUD: "f".repeat(64) })).access.audience).toBe("f".repeat(64));
    expect(configErrorFields(envWith({ CF_ACCESS_AUD: "kisa" }))).toEqual(["CF_ACCESS_AUD"]);
    expect(configErrorFields(envWith({ CF_ACCESS_TEAM_DOMAIN: "ornek.com" }))).toEqual(["CF_ACCESS_TEAM_DOMAIN"]);
    expect(configErrorFields(envWith({ DMG_URL: "http://indir.ornek.test/a.dmg" }))).toEqual(["DMG_URL"]);
  });

  it("DeviceCheck `required` iken ekip ve anahtar kimliği Apple biçiminde, anahtar PEM olmalı; `off` diğerlerine bakmaz", () => {
    expect(parseConfig(envWith({ DEVICECHECK_POLICY: "off", DEVICECHECK_KEY_ID: "DEVICECHECK_KEY_ID_PENDING" })).deviceCheck).toEqual({ policy: "off" });
    expect(configErrorFields(envWith({ DEVICECHECK_POLICY: "required", DEVICECHECK_KEY_ID: "DEVICECHECK_KEY_ID_PENDING" }))).toEqual([
      "DEVICECHECK_KEY_ID",
      "DEVICECHECK_PRIVATE_KEY",
    ]);
    const pem: string = "-----BEGIN PRIVATE KEY-----\nMIG\n-----END PRIVATE KEY-----";
    const required: Env = envWith({ DEVICECHECK_POLICY: "required", DEVICECHECK_KEY_ID: "ABCDE12345", DEVICECHECK_PRIVATE_KEY: pem });
    expect(parseConfig(required).deviceCheck).toMatchObject({ policy: "required", environment: "development", teamId: "79DZ4AA4DW", keyId: "ABCDE12345" });
    // Üretimde DeviceCheck geliştirme adresine bağlanamaz.
    expect(configErrorFields(envWith({ ...productionFilledIn, DEVICECHECK_POLICY: "required", DEVICECHECK_KEY_ID: "ABCDE12345", DEVICECHECK_PRIVATE_KEY: pem }))).toEqual([
      "DEVICECHECK_ENVIRONMENT",
    ]);
  });

  it("Stripe anahtarının modu önekten çıkar; tanınmayan önek, ayrı deneme sırrı ve hesap sınırı doğrulanır", () => {
    expect(parseConfig(envWith({ STRIPE_SECRET_KEY: "sk_test_0000000000000000" })).stripeMode).toBe("test");
    expect(parseConfig(envWith({ STRIPE_SECRET_KEY: "rk_test_0000000000000000" })).stripeMode).toBe("test");
    expect(parseConfig(envWith({ STRIPE_SECRET_KEY: "sk_live_0000000000000000" })).stripeMode).toBe("live");
    expect(parseConfig(envWith({ STRIPE_SECRET_KEY: "rk_live_0000000000000000" })).stripeMode).toBe("live");
    expect(configErrorFields(envWith({ STRIPE_SECRET_KEY: "pk_live_0000000000000000" }))).toEqual(["STRIPE_SECRET_KEY"]);
    expect(configErrorFields(envWith({ TRIAL_HASH_SECRET: "kısa" }))).toEqual(["TRIAL_HASH_SECRET"]);
    expect(configErrorFields(envWith({ MONTHLY_ACCOUNT_TOKEN_CAP: "7000000" }))).toEqual(["MONTHLY_ACCOUNT_TOKEN_CAP"]);
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
      fields: "APP_ATTEST_APP_IDS,GOOGLE_CLIENT_IDS,STRIPE_PRICE_ID,STRIPE_YEARLY_PRICE_ID",
    });
    expect((await harness.call(req("GET", "/v1/health", { env: productionFilledIn }))).status).toBe(200);
  });
});

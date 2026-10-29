import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

/** Sahte test gizli değerleri: gerçek anahtar değildir, yalnızca biçim doğrulamasını geçer. */
const fakeSecrets: Record<string, string> = {
  ACCESS_TOKEN_SECRET: "test-access-token-secret-0123456789abcdef",
  ANTHROPIC_API_KEY: "test-anthropic-key-000000",
  ELEVENLABS_API_KEY: "test-elevenlabs-key-00000",
  STRIPE_SECRET_KEY: "sk_test_fake_0000000000000",
  STRIPE_WEBHOOK_SECRET: "whsec_test_fake_000000000",
  TURNSTILE_SECRET_KEY: "test-turnstile-secret-000",
};

/**
 * Gerçek servis testleri yalnızca `AINOTEPAD_SERVER_LIVE_TESTS=1` ve ilgili test anahtarları ortamda varsa açılır;
 * anahtarlar dosyaya yazılmaz, yalnızca test Worker'ına bağlama olarak geçer.
 */
function liveBindings(): Record<string, string> {
  if (process.env["AINOTEPAD_SERVER_LIVE_TESTS"] !== "1") {
    return { LIVE_TESTS: "0" };
  }
  const names: string[] = ["LIVE_ANTHROPIC_API_KEY", "LIVE_STRIPE_SECRET_KEY", "LIVE_STRIPE_PRICE_ID"];
  const bindings: Record<string, string> = { LIVE_TESTS: "1" };
  for (const name of names) {
    const value: string | undefined = process.env[name];
    if (value !== undefined && value.length > 0) {
      bindings[name] = value;
    }
  }
  return bindings;
}

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: { ...fakeSecrets, ...liveBindings(), TEST_MIGRATIONS: migrations },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/setup.ts"],
      testTimeout: 60_000,
    },
  };
});

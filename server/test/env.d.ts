import type { D1Migration } from "cloudflare:test";
import type { Env as AppEnv } from "../src/env";

declare global {
  namespace Cloudflare {
    /** Test Worker'ının bağlamaları: uygulama ortamı + göçler + isteğe bağlı gerçek servis anahtarları. */
    interface Env extends AppEnv {
      readonly TEST_MIGRATIONS: D1Migration[];
      readonly LIVE_TESTS: string;
      readonly LIVE_ANTHROPIC_API_KEY?: string;
      readonly LIVE_STRIPE_SECRET_KEY?: string;
      readonly LIVE_STRIPE_PRICE_ID?: string;
    }
  }
}

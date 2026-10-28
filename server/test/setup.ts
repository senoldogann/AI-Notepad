import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Her test dosyası kendi D1 deposunu alır; göçler dosya başında uygulanır.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

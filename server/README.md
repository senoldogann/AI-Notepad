# AI-Notepad sunucusu (abonelik sürümü)

Cloudflare Worker + D1. Mac uygulamasının abonelik sürümü kullanıcı anahtarı olmadan çalışır: bu Worker bizim Anthropic
(yalnızca Claude Haiku 5.5) ve ElevenLabs anahtarlarımızla vekillik yapar, ödemeyi Stripe ile alır. Anahtarlar yalnızca
Worker gizli değerlerindedir. Plan: `docs/superpowers/plans/2026-10-28-abonelik-surumu.md`.

## Yerel geliştirme

```bash
cd server
npm ci
cp .dev.vars.example .dev.vars        # sahte ya da test anahtarlarıyla doldur; repoya girmez
npm run migrate:local
npm run dev                           # http://localhost:8787
npm run typecheck
npm test                              # Workers çalışma zamanında, gerçek D1 (miniflare); dış servisler sahte
```

Gerçek servis testleri (Stripe test modu, Anthropic Haiku) yalnızca açıkça istenirse çalışır:

```bash
AINOTEPAD_SERVER_LIVE_TESTS=1 LIVE_ANTHROPIC_API_KEY=... LIVE_STRIPE_SECRET_KEY=sk_test_... \
  LIVE_STRIPE_PRICE_ID=price_... npx vitest run test/live.test.ts
```

## Gizli değerler (`wrangler secret put <AD> --env production`)

`ACCESS_TOKEN_SECRET` (en az 32 karakter, rastgele), `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `STRIPE_SECRET_KEY`,
`STRIPE_WEBHOOK_SECRET`, `TURNSTILE_SECRET_KEY`, `RESEND_API_KEY` (yalnızca `EMAIL_SENDER=resend`).

Gizli olmayan ayarlar `wrangler.jsonc` içindeki `vars`'tadır (deneme sayısı, aylık sınır, bütçeler, fiyat kimliği,
App Attest politikası…). Eksik ya da geçersiz bir değer her istekte `500 internal_error` ve `config_invalid` logu verir.

## Göçler

`migrations/` altındaki SQL dosyaları sırayla uygulanır: yerelde `npm run migrate:local`, üretimde
`npm run migrate:production`. Yeni şema değişikliği yeni bir numaralı dosyadır; uygulanmış dosya değiştirilmez.

## İlk dağıtım (sahibin bir kez yapacakları)

1. `npx wrangler login`
2. `npx wrangler d1 create ainotepad-production` → çıkan `database_id`'yi `wrangler.jsonc` → `env.production` içine yaz.
3. `wrangler.jsonc` → `env.production.vars`: `SITE_ORIGIN`, `APPLE_CLIENT_IDS` (uygulama paket kimliği ve web Services
   ID), `APP_ATTEST_APP_IDS` (`TEAMID.imzalama-kimliği`), `EMAIL_FROM`, `EMAIL_LINK_URL`, `STRIPE_PRICE_ID`.
4. Yukarıdaki gizli değerleri `wrangler secret put … --env production` ile gir.
5. `npm run migrate:production`
6. `npm run deploy`
7. Stripe panelinde webhook uç noktası: `https://<worker>/v1/billing/webhook`, olaylar
   `customer.subscription.created|updated|deleted|paused|resumed`; imza sırrını `STRIPE_WEBHOOK_SECRET` yap.
   Stripe Tax'i ve Müşteri Portalı'nı panelden aç.
8. `curl https://<worker>/v1/health` → `{"status":"ok"}`

## Uçlar

| Uç | Kimlik | Not |
|---|---|---|
| `GET /v1/health` | — | |
| `POST /v1/auth/apple` | — | `{identityToken, nonce}`; Apple'a `sha256hex(nonce)` verilir |
| `POST /v1/auth/email/start` | — | `{email, turnstileToken}`; her zaman 202 |
| `POST /v1/auth/email/verify` | — | `{token}` (bağlantının `#token=` parçası) |
| `POST /v1/auth/refresh`, `/v1/auth/logout` | — | `{refreshToken}`; dönen jeton, yeniden kullanım aileyi düşürür |
| `GET /v1/me` | Bearer | plan, kalan deneme, aylık saat ve sınır, abonelik |
| `POST /v1/device/challenge` | Bearer | `{purpose: "attest" \| "assert"}` |
| `POST /v1/device/attest` | Bearer | `{keyId, attestation, challenge}` (base64) |
| `POST /v1/meetings/start` | Bearer | `{device?: {keyId, assertion, clientData}}`; clientData = `{"action":"meetings.start","challenge":…}` |
| `POST /v1/meetings/{id}/end` | Bearer | |
| `POST /v1/llm/messages` | Bearer + `x-meeting-id` | Anthropic Messages alt kümesi; `stream: true` ise SSE |
| `POST /v1/transcribe` | Bearer + `x-meeting-id` | gövde ham ses (`Content-Type: audio/…`, `Content-Length`); `?language_code=&diarize=&keyterms=` |
| `POST /v1/billing/checkout`, `/v1/billing/portal` | Bearer | `{url}` döner |
| `POST /v1/billing/webhook` | Stripe imzası | |

Hatalar her zaman `{"error": {"code", "message"}}` biçimindedir.

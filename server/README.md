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
Üretimde yer tutucu kalmışsa da öyledir (`TEAMID…` uygulama kimliği, `placeholder` içeren fiyat kimliği, `example.com` ya
da `localhost` adresleri): log `ConfigPlaceholderError` ve ayar adlarını taşır, değerleri değil. Yerelde ve testlerde
yer tutucular geçerlidir.

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
| `GET /v1/me` | Bearer | plan, etkin kalan deneme (isteğe bağlı `x-device-key-id` ile hesap ve cihazın küçüğü), aylık saat ve sınır, abonelik erişimi (`active` / `grace` / `none`) |
| `DELETE /v1/me` | Bearer | hesabı siler (GDPR), `204`: önce Stripe'taki bitmemiş abonelikler hemen iptal edilir (başarısızsa hiçbir şey silinmez, `502`); sonra kimlikler, oturumlar, giriş bağlantıları, cihazlar, toplantılar, kullanım, abonelik ve Stripe müşteri eşlemesi, deneme kayıtları tek işlemde silinir. Bugünkü deneme başlangıcı IP özeti başına günlük sayaçta hesap bağı olmadan kalır. Stripe'taki müşteri ve faturalar vergi kayıtları için Stripe'ta kalır. Tekrarı (aynı jetonla) `204` |
| `POST /v1/device/challenge` | Bearer | `{purpose: "attest" \| "assert"}` |
| `POST /v1/device/attest` | Bearer | `{keyId, attestation, challenge}` (base64) |
| `POST /v1/meetings/start` | Bearer | `{device?: {keyId, assertion, clientData}}`; clientData = `{"action":"meetings.start","challenge":…}`; yeni hesabın ilk denemesi IP başına günde 3; kullanıcı başına günde en çok 20 başlatma; yeni toplantı açık olanı ek süresiz kapatır, reddedilen başlatma açık toplantıya dokunmaz ve sayılmaz |
| `POST /v1/meetings/{id}/end` | Bearer | |
| `POST /v1/llm/messages` | Bearer + `x-meeting-id` | zorunlu `effort: "low" \| "medium"` + Anthropic Messages alt kümesi; `thinking` yok; `stream: true` ise SSE; toplantı bütçesi + kullanıcı başına aylık (6,5 M) ve günlük (3 M) token sınırı |
| `POST /v1/transcribe` | Bearer + `x-meeting-id` | gövde ham ses (`Content-Type: audio/…`, `Content-Length`); `?language_code=&diarize=&keyterms=`. Süre önceden ayrılır: WAV (PCM) başlıktan kesin, m4a/aac/mp3 en düşük 8 kbit/s, ogg/webm 6 kbit/s varsayımıyla; toplantının sesi en çok toplantının süresi kadar. FLAC kabul edilmez. Uzun toplantıda WAV parçalar halinde gönderilir |
| `POST /v1/billing/checkout`, `/v1/billing/portal` | Bearer | `{url}` döner; bitmemiş abonelik varken (`active`, `trialing`, `past_due`, `unpaid`, `incomplete`, `paused`; ek süre geçmiş olsa da) Checkout `409 subscription_exists` döner, istemci Portal'ı açar |
| `POST /v1/billing/webhook` | Stripe imzası | kullanıcı başına tek geçerli abonelik: başka bir aboneliğin olayı onu yalnızca geçerli olan bitmişse ya da gelen `active`/`trialing` iken geçerli olan öyle değilse değiştirir |

Hatalar her zaman `{"error": {"code", "message"}}` biçimindedir. Günlük harcama tavanı aşılınca toplantı başlatma ve her vekil çağrısı `503 spend_ceiling_reached` döner.

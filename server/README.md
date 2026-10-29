# Gistsmith sunucusu (abonelik sürümü)

Cloudflare Worker + D1. Mac uygulamasının abonelik sürümü kullanıcı anahtarı olmadan çalışır: bu Worker bizim Anthropic
(yalnızca Claude Haiku 5.5) ve ElevenLabs anahtarlarımızla vekillik yapar, ödemeyi Stripe ile alır. Anahtarlar yalnızca
Worker gizli değerlerindedir. Üretim adresi `https://api.gistsmith.com` (özel alan adı; geçiş süresince workers.dev
adresi de açık), site `https://gistsmith.com`. İç adlar (worker, D1, paket kimlikleri) `ainotepad` adını korur. Plan:
`docs/superpowers/plans/2026-10-28-abonelik-surumu.md`.

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
`STRIPE_WEBHOOK_SECRET`, `TURNSTILE_SECRET_KEY` (sitedeki iletişim formu), `DEVICECHECK_PRIVATE_KEY` (yalnızca
`DEVICECHECK_POLICY=required` iken: Apple Developer → Keys'te DeviceCheck yetkili anahtarın `.p8` dosyasının içeriği,
olduğu gibi: `npx wrangler secret put DEVICECHECK_PRIVATE_KEY --env production < AuthKey_XXXXXXXXXX.p8`).
`ACCESS_TOKEN_SECRET` değiştirilirse IP ve kimlik özetleri değişir: kimlik deneme defteri eski hesaplarla eşleşmez.

## Ayarlar (`wrangler.jsonc` → `vars`)

Gizli olmayan ayarlar `vars`'tadır (deneme sayısı, aylık sınır, bütçeler, fiyat kimliği, App Attest politikası…;
türetmeler dosyadaki açıklamalarda). Bu sürümle gelenler:

| Ayar | Anlamı |
|---|---|
| `GOOGLE_CLIENT_IDS` | Google kimlik jetonunda kabul edilen `aud` değerleri (virgülle). Mac uygulaması jetonu site üzerinden aldığı için yalnızca sitenin web istemcisi. |
| `ADMIN_IDENTITIES` | Yönetici API'sine erişen kimlikler, `apple:<sub>` ya da `google:<sub>` (virgülle). Boşsa kimse yönetici değildir. |
| `DMG_URL` | `GET /v1/download/mac` yönlendirmesinin hedefi (https). |
| `PRICE_USD_MONTHLY` | Aylık fiyat; yalnızca yönetici istatistiğindeki MRR tahmini için (Stripe fiyatıyla elle aynı tutulur). |
| `REPORTS_PER_DAY` | Tüm kullanıcılar için günlük rapor sınırı (geri bildirim, çökme, iletişim). |
| `DEVICECHECK_POLICY` | Mac başına ücretsiz deneme (Apple DeviceCheck) için tek anahtar: `required` (üretim) ya da `off` (yerel, testler: DeviceCheck hiç çağrılmaz). Ayrıntı: aşağıda "Deneme kötüye kullanımı". |
| `DEVICECHECK_ENVIRONMENT` | `production` (`api.devicecheck.apple.com`) ya da `development` (`api.development.devicecheck.apple.com`); üretimde `required` iken `production` olmalı. |
| `DEVICECHECK_TEAM_ID`, `DEVICECHECK_KEY_ID` | Yetki JWT'sinin `iss`'i (Apple ekip kimliği) ve `kid`'i (DeviceCheck anahtar kimliği); `required` iken 10 karakterlik Apple biçiminde olmalı (yer tutucu `DEVICECHECK_KEY_ID_PENDING` geçmez). |

Hız sınırları `ratelimits`'tedir (süre 10 ya da 60 sn): `AUTH_IP_LIMITER` (giriş, IP başına 10/dk), `API_IP_LIMITER`
(her uç, 300/dk), `START_USER_LIMITER` ve `PROXY_USER_LIMITER` (kullanıcı başına), `REPORT_IP_LIMITER` (raporlar, IP
başına 5/dk). Her ortamın kendi `namespace_id`'si vardır.

Eksik ya da geçersiz bir değer her istekte `500 internal_error` ve `config_invalid` logu verir. Üretimde yer tutucu
kalmışsa da öyledir (`TEAMID…` uygulama kimliği, `placeholder` içeren Google istemci ya da fiyat kimliği, `example.com`
ya da `localhost` adresleri): log `ConfigPlaceholderError` ve ayar adlarını taşır, değerleri değil. Yerelde ve
testlerde yer tutucular geçerlidir.

## Göçler

`migrations/` altındaki SQL dosyaları sırayla uygulanır: yerelde `npm run migrate:local`, üretimde
`npm run migrate:production`. Yeni şema değişikliği yeni bir numaralı dosyadır; uygulanmış dosya değiştirilmez.
`0007` e-posta giriş tablosunu siler ve `auth_identities` tablosunu `google` sağlayıcısına izin verecek biçimde yeniden
kurar (`email` kimliği varsa göç açıkça başarısız olur; üretimde e-posta hiç gönderilmediği için yoktur). `0008`
raporları, indirme sayacını ve istatistik dizinlerini ekler. `0009` kimlik deneme defterini ve kullanıcının devraldığı
deneme sayısı ile Mac doğrulama anını ekler (aşağıda "Deneme kötüye kullanımı").

## Deneme kötüye kullanımı

Deneme hesap başına `TRIAL_MEETINGS` toplantıdır; üç ek engel vardır:

- **Kimlik deneme defteri** (`src/trialLedger.ts`): hesap silinince her giriş kimliği için (`trial-identity:<sağlayıcı>:<sub>`
  metninin `ACCESS_TOKEN_SECRET` ile HMAC özeti; kimlik açık saklanmaz) harcanan deneme sayısı ve Mac doğrulaması
  `trial_identity_ledger`'a yazılır. Aynı kimlikle yeniden açılan hesap bunları devralır
  (`users.carried_trial_meetings`, `users.trial_device_verified_at`) ve IP sınırına yeni deneme hesabı olarak girmez.
  Satır son güncellemeden 730 gün sonra silinir.
- **Mac başına deneme** (`src/deviceCheck.ts`, `DEVICECHECK_POLICY=required`): Apple DeviceCheck her Mac için iki bit
  saklar; sunucu cihaz kimliği görmez. `bit0` = "bu Mac bir hesaba deneme verdi" (`bit1` kullanılmaz, korunur).
  Denemesi henüz bir Mac'e bağlanmamış hesabın deneme toplantısı `deviceCheckToken` ister (`400 device_check_required`);
  `bit0` doluysa `403 trial_device_used`; boşsa Mac işaretlenir ve hesap doğrulanmış sayılır (sonraki deneme
  toplantıları jeton istemez). Apple 400 verirse `400 device_check_invalid`; 5xx/429/ağ hatası uyarıyla 3 kez denenir,
  sonra `502 upstream_unavailable`. Abonelik toplantısı ve denemesi bitmiş hesap DeviceCheck çağırmaz. `off` iken
  DeviceCheck hiç çağrılmaz.
- **IP başına yeni deneme hesabı**: `TRIAL_ACCOUNTS_PER_IP_PER_DAY` (IP'nin HMAC özeti, gün sonunda silinir).

App Attest (`APP_ATTEST_POLICY`) macOS'ta desteklenmediği için bugün cihaz sınırı vermez; kodu yerinde durur.

## Zamanlanmış temizlik

`wrangler.jsonc` → `triggers.crons` her gün 03:17 UTC'de `scheduled` işleyicisini çalıştırır (`src/cleanup.ts`). Silinenler:
süresi dolmuş nonce'lar (Apple ve Google), süresi dolmuş ya da kullanılmış cihaz meydan okumaları, süresi dolmuş ya da
ailesi düşürülmüş yenileme jetonları ve jetonu kalmamış aileler, 90 günden eski Stripe olayları ve günlük harcama, bugünden
eski deneme başlangıçları, 2 günden eski kullanıcı günlük kullanımı, 180 günden eski raporlar (durumundan bağımsız), 730
gündür güncellenmemiş kimlik deneme defteri satırları.
İndirme sayacı (gün başına tek satır, kişisel veri yok) silinmez. Silme tablo başına 1000 satırlık en çok 4 turdur; kalan
ertesi gün silinir (`cleanup_incomplete` uyarısı). Yerelde: `npx wrangler dev --test-scheduled`, sonra
`curl "http://localhost:8787/__scheduled?cron=17+3+*+*+*"`.

## İlk dağıtım (sahibin bir kez yapacakları)

1. `npx wrangler login`
2. `npx wrangler d1 create ainotepad-production` → çıkan `database_id`'yi `wrangler.jsonc` → `env.production` içine yaz.
3. `wrangler.jsonc` → `env.production`:
   - `routes`: `api.gistsmith.com` özel alan adı (gistsmith.com bölgesi aynı Cloudflare hesabında olmalı; dağıtımda
     DNS kaydı ve sertifika kendiliğinden kurulur). `workers_dev: true` geçiş bitene dek kalır.
   - `vars`: `SITE_ORIGIN` (`https://gistsmith.com`), `APP_ATTEST_APP_IDS` (`TEAMID.com.senoldogan.AINotepad.hosted`),
     `STRIPE_PRICE_ID`, `GOOGLE_CLIENT_IDS` (Google Cloud Console → sitenin OAuth web istemcisi), `DMG_URL`,
     `PRICE_USD_MONTHLY` (Stripe fiyatıyla aynı), `REPORTS_PER_DAY`. `APPLE_CLIENT_IDS` hazırdır:
     `com.senoldogan.AINotepad.hosted` (abonelik uygulamasının paket kimliği) ve `com.senoldogan.AINotepad.web` (sitenin
     Apple ile giriş Services ID'si; bkz. `web/README.md`).
   - `ADMIN_IDENTITIES` önce boş kalır. Dağıtımdan sonra sitede kendi hesabınla giriş yapıp `GET /v1/admin/stats`
     çağır: `403` yanıtındaki `error.identity` (`google:…` ya da `apple:…`) senin kimliğindir; onu yazıp yeniden dağıt.
4. Yukarıdaki gizli değerleri `wrangler secret put … --env production` ile gir.
5. `npm run migrate:production`
6. `npm run deploy`
7. Stripe panelinde webhook uç noktası: `https://api.gistsmith.com/v1/billing/webhook`, olaylar
   `customer.subscription.created|updated|deleted|paused|resumed`; imza sırrını `STRIPE_WEBHOOK_SECRET` yap.
   Stripe Tax'i ve Müşteri Portalı'nı panelden aç.
8. `curl https://api.gistsmith.com/v1/health` → `{"status":"ok"}`
9. Önerilen: Cloudflare panelinde `api.gistsmith.com` için bir WAF hız sınırı kuralı. Workers Free planının hesap
   genelindeki günlük 100 000 istek ve D1 yazma kotası Worker'ın kendi hız sınırlarından önce tükenebilir (fatura değil,
   kesinti riski).

## Uçlar

| Uç | Kimlik | Not |
|---|---|---|
| `GET /v1/health` | — | |
| `POST /v1/auth/apple` | — | `{identityToken, nonce}`; Apple'a `sha256hex(nonce)` verilir |
| `POST /v1/auth/google` | — | `{identityToken, nonce}`; Google'a `sha256hex(nonce)` verilir. `iss` `https://accounts.google.com` ya da `accounts.google.com`, `aud` ∈ `GOOGLE_CLIENT_IDS`, RS256, nonce tek kullanımlık. Kimlik `google:<sub>`; e-posta saklanmaz. Apple hesabıyla otomatik bağlama yoktur (ayrı kullanıcı). Oturum yanıtı ve deneme kuralları Apple ile aynı |
| `POST /v1/auth/refresh`, `/v1/auth/logout` | — | `{refreshToken}`; dönen jeton, yeniden kullanım aileyi düşürür |
| `GET /v1/me` | Bearer | plan, etkin kalan deneme (isteğe bağlı `x-device-key-id` ile hesap ve cihazın küçüğü), aylık saat ve sınır, abonelik erişimi (`active` / `grace` / `none`) |
| `DELETE /v1/me` | Bearer | hesabı siler (GDPR), `204`: önce Stripe'taki bitmemiş abonelikler hemen iptal edilir (başarısızsa hiçbir şey silinmez, `502`); sonra kimlikler, oturumlar, cihazlar, toplantılar, kullanım, abonelik ve Stripe müşteri eşlemesi, deneme kayıtları ve hesabın raporları tek işlemde silinir; aynı işlemde önce her kimliğin deneme defteri satırı yazılır (harcanan deneme ve Mac doğrulaması, kimliğin HMAC özetiyle; deneme harcanmadıysa yazılmaz) (raporlar serbest metin ve e-posta taşıyabildiği için bağı kaldırılmaz, silinir; jetonsuz gönderilmiş raporlar hesaba bağlanamaz, 180 günde silinir). Bugünkü deneme başlangıcı IP özeti başına günlük sayaçta hesap bağı olmadan kalır. Stripe'taki müşteri ve faturalar vergi kayıtları için Stripe'ta kalır. Tekrarı (aynı jetonla) `204` |
| `POST /v1/device/challenge` | Bearer | `{purpose: "attest" \| "assert"}` |
| `POST /v1/device/attest` | Bearer | `{keyId, attestation, challenge}` (base64) |
| `POST /v1/meetings/start` | Bearer | `{device?: {keyId, assertion, clientData}, deviceCheckToken?: <base64>}`; clientData = `{"action":"meetings.start","challenge":…}`; `deviceCheckToken` (`DCDevice.generateToken()`) denemesi henüz bir Mac'e bağlanmamış hesabın deneme toplantısında gerekir (bkz. "Deneme kötüye kullanımı"); yeni hesabın ilk denemesi IP başına günde 3; kullanıcı başına günde en çok 20 başlatma; yeni toplantı açık olanı ek süresiz kapatır, reddedilen başlatma açık toplantıya dokunmaz ve sayılmaz |
| `POST /v1/meetings/{id}/end` | Bearer | |
| `POST /v1/llm/messages` | Bearer, isteğe bağlı `x-meeting-id` | zorunlu `effort: "low" \| "medium"` + Anthropic Messages alt kümesi; `thinking` yok; `stream: true` ise SSE. `x-meeting-id` varsa (kayıt sırasındaki çeviri, "Ne kaçırdım?", soru) toplantı açık ya da ek sürede olmalı, toplantı bütçesinden düşer, çağrı başı `LLM_MAX_TOKENS`. Yoksa hesap çağrısıdır (Sor, notu yeniden yazma, düzenleme, paylaşım çevirisi, görev aracı): erişimi olan abonelik ya da kullanılmamış deneme gerekir (yoksa `402 subscription_required`), çağrı başı daha küçük `LLM_ACCOUNT_MAX_TOKENS`; aboneliği olmayan kullanıcıda bu çağrılar ayrıca günlük `TRIAL_ACCOUNT_DAILY_TOKENS` (300 K; türetme `wrangler.jsonc`'ta) ile sınırlıdır (`429 daily_cap_reached`). Her iki durumda kullanıcı başına aylık (6,5 M) ve günlük (3 M) token sınırı ve harcama tavanı |
| `POST /v1/transcribe` | Bearer + `x-meeting-id` | gövde ham ses (`Content-Type: audio/…`, `Content-Length`); `?language_code=&diarize=&keyterms=`. Süre önceden ayrılır: WAV (PCM) başlıktan kesin, m4a/aac/mp3 en düşük 8 kbit/s, ogg/webm 6 kbit/s varsayımıyla; toplantının sesi en çok toplantının süresi kadar. FLAC kabul edilmez. Uzun toplantıda WAV parçalar halinde gönderilir |
| `POST /v1/billing/checkout`, `/v1/billing/portal` | Bearer | `{url}` döner; bitmemiş abonelik varken (`active`, `trialing`, `past_due`, `unpaid`, `incomplete`, `paused`; ek süre geçmiş olsa da) Checkout `409 subscription_exists` döner, istemci Portal'ı açar |
| `POST /v1/billing/webhook` | Stripe imzası | kullanıcı başına tek geçerli abonelik: başka bir aboneliğin olayı onu yalnızca geçerli olan bitmişse ya da gelen `active`/`trialing` iken geçerli olan öyle değilse değiştirir |
| `POST /v1/reports` | isteğe bağlı Bearer | `{kind, message?, email?, appVersion?, os?, payload?, turnstileToken?}` → `202 {}`. `contact` (site): `message` (≤5000), `email` (≤254) ve `turnstileToken` zorunlu, Turnstile doğrulanır. `feedback`: `message` zorunlu. `crash`: `payload` zorunlu (JSON nesnesi, ≤512 K karakter; MetricKit ise listede kısa imza). `appVersion` ≤40, `os` ≤80. Türe ait olmayan alan reddedilir (ör. `feedback` + `payload`, `crash` + `turnstileToken`). Jeton varsa geçerli olmalı (`401`), rapor hesaba bağlanır. Gövde ayrıştırmadan önce en çok 768 KB (`413`); IP başına 5/dk, günde toplam `REPORTS_PER_DAY` (`429 daily_cap_reached`) |
| `GET /v1/download/mac` | — | `302` → `DMG_URL`; UTC gün sayacını artırır (IP, tarayıcı ya da tanımlayıcı saklanmaz). Sayaç yazılamazsa yine yönlendirir (`download_count_failed` uyarısı) |
| `GET /v1/admin/stats` | Bearer + yönetici | indirme, kullanıcı, deneme, abonelik (MRR = (`active` − `ending`) × `PRICE_USD_MONTHLY`), toplantı, harcama, token ve açık rapor özetleri; 30 günlük seriler (UTC, eskiden yeniye, boş gün 0). Tanımlar `src/admin.ts` → `adminStats` |
| `GET /v1/admin/reports` | Bearer + yönetici | `?kind=&status=&before=<ms>` → `{items: [{id, kind, status, createdAt, userId, email, appVersion, os, summary}], nextBefore}`; sayfa 50, yeniden eskiye, `createdAt` ISO 8601, `nextBefore` ms ya da son sayfada `null` |
| `GET /v1/admin/reports/{id}` | Bearer + yönetici | `{id, kind, status, createdAt, userId, email, appVersion, os, message, payload}` |
| `POST /v1/admin/reports/{id}` | Bearer + yönetici | `{status: "open" \| "done"}` → `204` |

Hatalar her zaman `{"error": {"code", "message"}}` biçimindedir; yönetici olmayan kullanıcının yönetici isteği
`403 {"error": {"code": "forbidden", "message", "identity"}}` döner (`identity`: çağıranın kendi kimlikleri, virgülle).
Günlük harcama tavanı aşılınca toplantı başlatma ve her vekil çağrısı `503 spend_ceiling_reached` döner. Site kaynağı
(`SITE_ORIGIN`) CORS'u yalnızca site uçlarında (giriş, `/v1/me`, ödeme, raporlar) ve yönetici uçlarında alır; her yanıt
`Cache-Control: no-store` taşır.

# Gistsmith sunucusu (abonelik sürümü)

Cloudflare Worker + D1. Mac uygulamasının abonelik sürümü kullanıcı anahtarı olmadan çalışır: bu Worker bizim Anthropic
(yalnızca Claude Haiku 5.5) ve ElevenLabs anahtarlarımızla vekillik yapar, ödemeyi Stripe ile alır. Anahtarlar yalnızca
Worker gizli değerlerindedir. Üretim adresi yalnızca `https://api.gistsmith.com` (özel alan adı; workers.dev ve
önizleme adresleri kapalı, bölgenin WAF kuralı atlanamasın diye), site `https://gistsmith.com`. İç adlar (worker, D1,
paket kimlikleri) `ainotepad` adını korur. Plan: `docs/superpowers/plans/2026-10-28-abonelik-surumu.md`.

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

`ACCESS_TOKEN_SECRET` (en az 32 karakter, rastgele), `TRIAL_HASH_SECRET` (en az 32 karakter, rastgele; erişim jetonu
sırrından farklı), `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `STRIPE_SECRET_KEY`,
`STRIPE_WEBHOOK_SECRET`, `TURNSTILE_SECRET_KEY` (sitedeki iletişim formu), `DEVICECHECK_PRIVATE_KEY` (yalnızca
`DEVICECHECK_POLICY=required` iken: Apple Developer → Keys'te DeviceCheck yetkili anahtarın `.p8` dosyasının içeriği,
olduğu gibi: `npx wrangler secret put DEVICECHECK_PRIVATE_KEY --env production < AuthKey_XXXXXXXXXX.p8`),
`DEEPGRAM_API_KEY` (yalnızca `DEEPGRAM_POLICY=on` iken: Deepgram konsolunda Member ya da üstü yetkili anahtar; yalnızca
kısa ömürlü jeton vermek için kullanılır), `GITHUB_BLOG_TOKEN` (isteğe bağlı; yönetim panelinden blog yayını, aşağıda
"Blog yayını"; girilmemişse blog uçları `503 blog_unavailable`; girilmişse boşluksuz ve en az 20 karakter olmalı, değilse
her istek `500`).
`TRIAL_HASH_SECRET` kimlik deneme defterinin, deneme IP özetlerinin ve davet edilenin kart parmak izi özetinin HMAC
sırrıdır (webhook da okur); değiştirilirse defterdeki eski satırlar yeni girişlerle eşleşmez (silinmiş hesabın kimliği
denemeyi yeniden alabilir, eski davetlerin kartları yeniden kullanılabilir). `ACCESS_TOKEN_SECRET`
değiştirilirse yalnızca açık oturumlar düşer. Hız sınırı ve IP özeti IPv6'da adresin /64 önekine göredir.

## Ayarlar (`wrangler.jsonc` → `vars`)

Gizli olmayan ayarlar `vars`'tadır (deneme sayısı, aylık sınır, bütçeler, fiyat kimliği, App Attest politikası…;
türetmeler dosyadaki açıklamalarda). Bu sürümle gelenler:

| Ayar | Anlamı |
|---|---|
| `GOOGLE_CLIENT_IDS` | Google kimlik jetonunda kabul edilen `aud` değerleri (virgülle). Mac uygulaması jetonu site üzerinden aldığı için yalnızca sitenin web istemcisi. |
| `ADMIN_IDENTITIES` | Yönetici API'sine erişen kimlikler, `apple:<sub>` ya da `google:<sub>` (virgülle). Boşsa kimse yönetici değildir. |
| `DMG_URL` | `GET /v1/download/mac` yönlendirmesinin hedefi (https). |
| `STRIPE_PRICE_ID`, `STRIPE_YEARLY_PRICE_ID` | Aynı ürünün aylık (varsayılan) ve yıllık fiyatı. Checkout `plan`'a göre birini kullanır; webhook, iade ve itiraz ikisini de "bizim" sayar; abonelik satırına plan (`monthly`/`yearly`) yazılır. Haklar plana bakmaz. İkisi aynı olamaz. |
| `PRICE_USD_MONTHLY`, `PRICE_USD_YEARLY` | Fiyatlar (Stripe fiyatlarıyla elle aynı tutulur; Stripe çağrılmaz). Aylık: MRR, yıllık davet indirimi tutarı ve davet ödülü (bakiye alacağı). Yıllık: yalnızca MRR (ayda 1/12'si). |
| `REFERRAL_POLICY` | Davet programı: `on` ise abonelere kod verilir ve Checkout kodu kabul eder; `off` ise kod verilmez, kod `503 referral_unavailable` alır; hak kazanılmış bekleyen ödüller yine verilir. Ayrıntı: aşağıda "Davet programı". |
| `REFERRAL_MAX_PENDING` | Davet edenin aynı anda açık tutabileceği en çok davet (3): ödülü bekleyen, son 24 saatte Checkout'a götürülen ve son 365 günde kart yüzünden düşen davetler; dolunca kod `409 referral_limit_reached` alır. |
| `MONTHLY_ACCOUNT_TOKEN_CAP` | Abonenin toplantıya bağlı olmayan çağrılarının (Sor, not düzenleme…) aylık token sınırı; `MONTHLY_TOKEN_CAP`'in parçası, ondan büyük olamaz. Toplantı bütçeleri değişmez. |
| `ELEVENLABS_MONTHLY_AUDIO_HOURS`, `ELEVENLABS_BILLING_DAY` | ElevenLabs aylık kredi planının ses saati (Creator: ~110 saat) ve yenilendiği gün (1–28, UTC). Dönem kullanımı `daily_spend.audio_seconds`'tan; %80 ve %95 aşılınca `elevenlabs_capacity_threshold` alarmı, eşik üstündeyken her gün Cron'da `elevenlabs_capacity_high` alarmı; `GET /v1/admin/stats` → `elevenLabs: {cycleStart, usedHours, capHours, percent}`. |
| `REPORT_BYTES_PER_DAY` | Rapor türü başına (geri bildirim, çökme, iletişim ayrı) tüm kullanıcılar için günlük bayt bütçesi; ayrıca hesap başına günde 20 rapor. |
| `TRIAL_DAYS` | Denemenin süresi (gün); hesabın ilk deneme toplantısıyla başlar. Deneme `TRIAL_MEETINGS` toplantı ya da bu süre, hangisi önce dolarsa. |
| `DAILY_TRIAL_SPEND_CEILING_USD` | Deneme harcamasının (deneme toplantıları + denemedeki toplantı dışı çağrılar) ayrı günlük tavanı; aşılınca deneme harcaması açan her istek (yeni ve açık deneme toplantıları, yeniden işleme, denemedeki hesap çağrısı) `503 trial_capacity_reached` (`daily_trial_spend_ceiling_reached` alarmı, günde bir kez). Aboneler yalnızca `DAILY_SPEND_CEILING_USD`'ye tabidir. |
| `DEVICECHECK_POLICY` | Mac başına ücretsiz deneme (Apple DeviceCheck) için tek anahtar: `required` (üretim) ya da `off` (yerel, testler: DeviceCheck hiç çağrılmaz). Ayrıntı: aşağıda "Deneme kötüye kullanımı". |
| `DEVICECHECK_ENVIRONMENT` | `production` (`api.devicecheck.apple.com`) ya da `development` (`api.development.devicecheck.apple.com`); üretimde `required` iken `production` olmalı. |
| `DEEPGRAM_POLICY` | Deepgram canlı metni için tek anahtar: `on` (üretim) ya da `off` (yerel, testler, acil kapatma: jeton verilmez, `/v1/me` → `liveEngine: "whisperkit"`, uygulama canlı metni Mac'te üretir). Ayrıntı: aşağıda "Deepgram canlı metni". |
| `DEEPGRAM_BUDGET_USD`, `DEEPGRAM_USD_PER_MINUTE` | Ücretsiz Deepgram kredisinin canlı metne ayrılan ömür boyu bütçesi (üretim 185; kredinin kalanı payı) ve akış dakikası fiyatı (Nova-3 çok dilli liste fiyatı 0,0092; temkinli). `GET /v1/admin/stats` → `deepgram: {policy, budgetUsd, estimatedUsd, percent, streamMinutes, meetings, openMeetings, usdPerMinute}`. |
| `GITHUB_BLOG_REPO`, `GITHUB_BLOG_BRANCH` | Blog yazılarının deposu (`sahip/ad`, `senoldogann/AI-Notepad`) ve yazıların commit'lendiği dal (`main`); yazılar `web/src/content/blog/*.md`. Ayrıntı: aşağıda "Blog yayını". |
| `DEVICECHECK_TEAM_ID`, `DEVICECHECK_KEY_ID` | Yetki JWT'sinin `iss`'i (Apple ekip kimliği) ve `kid`'i (DeviceCheck anahtar kimliği); `required` iken 10 karakterlik Apple biçiminde olmalı (yer tutucu `DEVICECHECK_KEY_ID_PENDING` geçmez). |

Hız sınırları `ratelimits`'tedir (süre 10 ya da 60 sn): `AUTH_IP_LIMITER` (giriş, IP başına 10/dk), `API_IP_LIMITER`
(her uç, 1200/dk), `START_USER_LIMITER` ve `PROXY_USER_LIMITER` (kullanıcı başına), `REPORT_IP_LIMITER` (raporlar, IP
başına 5/dk), `DEEPGRAM_USER_LIMITER` (Deepgram jetonu, kullanıcı başına 10/dk). Her ortamın kendi `namespace_id`'si
vardır. IP sınırı yalnızca kimliksiz sel için kaba bir kapıdır: asıl maliyet kullanıcı başına sınırlardadır
(`PROXY_USER_LIMITER` 120/dk). Aynı NAT ya da operatör CGNAT'ı arkasında canlı çeviri yapan kişi dakikada ~15 istek
attığından 300/dk ~20 kişide 429 veriyordu; 1200/dk ~80 kişiye yeter. Kimliksiz uçlar bu sınırda bile D1 yazımı
harcatamaz: `/v1/health` D1'e dokunmaz, `/v1/download/mac` ağ başına günde bir kez yazar.

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
deneme sayısı ile Mac doğrulama anını ekler (aşağıda "Deneme kötüye kullanımı"). `0010` denemenin başladığı anı
(`users.trial_started_at`, defterde de) ekler; var olan hesaplar ilk deneme toplantısından, var olan defter satırları
silinme anından doldurulur. `0011` raporların bayt boyunu (`reports.size_bytes`, tür başına günlük bütçe) ekler.
`0012` süreli ayırma satırlarını (`usage_reservations`, aşağıda "Ayırma ve kesinleştirme") ve abonenin toplantı dışı
token sayacını (`monthly_usage.account_tokens`) ekler; eski `*_reserved` sayaç sütunları artık kullanılmaz. `0013`
yenileme jetonunun yerine geçen jetonu (`refresh_tokens.replaced_by`) ekler. `0014` aboneliğin `past_due`'ya geçtiği anı
(`subscriptions.past_due_since`; var olan `past_due` satırları son webhook yazımından) ekler. `0015` giriş kimliklerindeki
e-postaları siler (yeni girişlerde de saklanmaz) ve cihaz saklama temizliği için dizin ekler. `0016` ElevenLabs'e giden
ses saniyesinin günlük toplamını (`daily_spend.audio_seconds`) ekler; sayaç göçle sıfırdan başlar. `0017` Deepgram canlı
metninin toplantı başına jeton sayısını ve bütçe tahminini (`deepgram_live_meetings`) ekler; satırlar silinmez (bütçe
ömür boyu) ve kullanıcıya bağlanmaz. `0018` kimlik defterine o ayın kullanımını (`usage_month`, `usage_seconds`,
`usage_tokens`, `usage_account_tokens`) ve `monthly_usage`'a devralınan süreyi (`carried_seconds`) ekler (aşağıda
"Deneme kötüye kullanımı"). `0032` Deepgram bütçesinin tek satırlık toplamını (`deepgram_budget`, tetikleyicilerle
güncellenir; var olan satırlardan doldurulur) ekler: bütçe denetimi tabloyu taramaz. `0033` "Sorunlar" sayacını
(`ops_events`) ve tavan alarmlarının günlük işaretini (`daily_spend.ceiling_alerted_at`, `trial_ceiling_alerted_at`),
`0034` indirme kaynaklarını (`download_sources`) ve ağ başına günlük tekilleştirmeyi (`download_visitors`), `0035`
toplantının ilk not anını ve hata alanlarını (`meeting_sessions.first_note_at`, `failure_count`, `last_failure_code`,
`last_failure_at`), `0036` Stripe iptal nedenlerini (`subscription_cancellations`), `0040` davet edilenin kart parmak
izi özetini (`referral_redemptions.card_fingerprint_hash`; aşağıda "Davet programı") ekler.

## Deepgram canlı metni

`POST /v1/live/deepgram-token` (bearer, `x-meeting-id` başlığı, gövde yok) açık (bitmemiş, ek süre sayılmaz) toplantıya
Deepgram'ın kısa ömürlü jetonunu verir: `{accessToken, expiresIn, model: "nova-3", mipOptOut: true, grantsLeft}`.
Sunucu `POST https://api.deepgram.com/v1/auth/grant`'ı `Authorization: Token <DEEPGRAM_API_KEY>` ve
`{"ttl_seconds": 30}` ile çağırır (5xx/429/ağ hatası uyarıyla 3 kez, sonra `502 upstream_unavailable`); uygulama
`wss://api.deepgram.com/v1/listen`'a `Authorization: Bearer <jeton>` ve `mip_opt_out=true` ile bağlanır. Jeton yalnızca
bağlantı kurulurken geçerli olmalıdır; her bağlantı ve yeniden bağlanma yeni jeton ister: toplantı başına en çok 30
(deneme toplantısında 12), 5 dakikada en çok 8 (`429 deepgram_grant_limit`). Jeton loglanmaz ve saklanmaz.

Sunucu akışı görmez; harcama temkinli tahmindir: toplantının ilk jetonunda kalan en çok süresi × 2 akış ("Sen" ve
"Diğerleri") peşin sayılır, toplantı bitince (`/end`, yeni toplantının kapattığı toplantı bir sonraki bitişte ya da günlük
Cron'da) ilk jetondan bitişe geçen gerçek süreye indirilir. Tahmin `DEEPGRAM_BUDGET_USD`'ye ulaşınca yeni toplantılar jeton
alamaz (`503 deepgram_unavailable`, `deepgram_budget_exhausted` uyarısı) ve `/v1/me` `liveEngine: "whisperkit"` der;
jeton almış toplantının yeniden bağlanmaları sürer. Bütçeyi en çok bir toplantının penceresi kadar (4 saat × 2 akış ≈
4,4 $) aşabilir. %80 ve %95 aşılınca `deepgram_budget_threshold` alarmı. `DEEPGRAM_POLICY=off` iken de jeton verilmez.

## Blog yayını

Yönetim panelinin Blog görünümü sitenin blog yazılarını (`web/src/content/blog/<kısa ad>.md`) GitHub üzerinden yönetir
(`src/blog.ts`): okuma ve yazma GitHub REST contents API'siyle, liste tek GraphQL isteğiyle (yazı başına istek Worker'ın
alt istek sınırına takılırdı). Her kayıt `GITHUB_BLOG_BRANCH` dalına bir commit'tir (`blog: <başlık>`, silmede
`blog: remove <kısa ad>`); commit sitenin yayın iş akışını tetikler (`.github/workflows/deploy-web.yml`; ayrıca her gün
06:00 UTC'de derlenir, zamanlanmış yazılar tarihlerinde yayımlanır). Haftalık akış: yaz → zamanla (gelecek tarihli kaydet)
→ günlük derleme yayımlar → paylaş (panelde X, LinkedIn, Bluesky); ayrıntı `web/README.md` "Haftalık blog".

- **Kurallar** içerik şemasıyla (`web/src/content.config.ts`) aynıdır: başlık 10–90, açıklama 50–170 karakter, yazar boş
  değil, `published` gerçek bir `YYYY-MM-DD` günü, `updated` null ya da `published`'dan önce olmayan gerçek bir gün,
  `cover` null ya da sitenin film ailelerinden biri (`sunset`, `coral`, `ocean`, `mint`, `rose`, `violet`; liste
  `web/src/lib/film.ts` ile aynı, test denetler), `draft` mantıksal, gövde boş değil ve en çok 60 000 karakter, kısa ad
  `^[a-z0-9]+(-[a-z0-9]+)*$` ve en çok 80 karakter. Başlık, açıklama ve yazarda denetim karakteri (satır sonu dahil)
  olamaz; gövdede `\r` ve sekme/satır sonu dışı denetim karakteri olamaz.
- **Dosya biçimi** sabittir: `title`, `description`, `author` JSON kaçışlı çift tırnakta (YAML 1.2'de geçerli), ardından
  `published: YYYY-MM-DD`, doluysa `updated: YYYY-MM-DD` ve `cover: <aile>`, `draft: true|false`, boş satır, gövde
  (baştaki boş satırlar ve sondaki boşluk atılır) ve tek satır sonu. Okurken yalnızca bu yedi alan kabul edilir
  (`updated` ve `cover` isteğe bağlı; bilinmeyen alan kayıtta kaybolmasın diye reddedilir, yazılmış ama geçersiz isteğe
  bağlı alan da); okunamayan dosya `500 blog_post_invalid` (dosya adıyla; site de derlenemez).
- **Sürüm:** güncelleme ve silme panelin açtığı sürümü (`sha`) ister; arada değişmişse hiçbir şey yazılmaz
  (`409 blog_conflict`). Kısa ad yazı varken değişmez (adres sabit kalır).
- **Görseller:** `web/public/blog/<kısa ad>/<ad>.webp` (sitede `/blog/<kısa ad>/<ad>.webp`). Panel tarayıcıda en çok
  1600 px genişliğe küçültüp WebP'ye çevirir; sunucu yeniden denetler: ad `^[a-z0-9-]+\.webp$` ve en çok 80 karakter
  (`400 bad_request`), gövde katı `{data}` standart base64 (`400 invalid_body`), çözülmüş en çok 600 KB
  (`413 payload_too_large`), RIFF/WEBP imzası ve RIFF boyu dosyayla tutmalı, ilk parça `VP8 `/`VP8L`/`VP8X`
  (`415 unsupported_media_type`), genişlik 1–1600 px (`400 invalid_body`). Yazı depoda olmalı (`404 not_found`: klasör
  kısa adla anılır, panel önce kaydettirir); aynı adda görsel varsa `409 blog_image_exists` (görseller değiştirilmez, yeni
  adla yüklenir). Yazım contents API'yle tek commit'tir (`blog: image <kısa ad>/<ad>`).
- **Silme** yazıyı ve görsel klasörünü tek commit'te siler (`blog: remove <kısa ad>`): dalın başındaki commit, yazının
  sürümü ve klasörün dosyaları tek GraphQL isteğiyle aynı commit'ten okunur, silme `createCommitOnBranch` ile beklenen dal
  başına yapılır. Dal arada başka bir commit'le ilerlerse (yazı aynı kaldıkça) `blog_delete_stale_head` uyarısıyla
  yeniden okunup 3 kez denenir, sonra `409 blog_conflict`. Klasörde alt klasör varsa `500 blog_post_invalid` (elle
  temizlenir).
- **GitHub hataları:** 408, 429, 5xx, ağ hatası ve zaman aşımı `upstream_retry` uyarısıyla 3 kez denenir (10 sn zaman
  aşımı), sonra `502 upstream_unavailable`; ret (401, 403, 422…) `502 upstream_rejected` (GraphQL hataları
  `github_graphql_failed` uyarısıyla). GitHub'ın hata gövdesi `github_request_failed` uyarısında loglanır, jeton
  loglanmaz. Kayıt, silme ve görsel yükleme kullanıcı başına dakikada 10'dur (`START_USER_LIMITER`, doğrulamadan sonra).
  Başarılı yazımlar `blog_post_saved` / `blog_post_deleted` (silinen görsel sayısıyla) / `blog_image_saved` loglanır.
- **Jeton:** GitHub → Settings → Developer settings → Fine-grained personal access tokens → yalnızca
  `senoldogann/AI-Notepad` deposu, "Repository permissions › Contents: Read and write" (Metadata: Read kendiliğinden gelir);
  başka yetki gerekmez. `npx wrangler secret put GITHUB_BLOG_TOKEN --env production`. Jetonun süresi dolunca blog uçları
  `502 upstream_rejected` döner; yenisi aynı komutla girilir. `main` dalı koruma kuralıyla doğrudan gönderime kapatılırsa
  jetonun sahibi kuralı atlayabilmeli, yoksa kayıt `upstream_rejected` alır.

## Ayırma ve kesinleştirme

Üst servise giden her çağrı (Anthropic, ElevenLabs) önce en kötü durum miktarını (LLM: tahmini girdi + `max_tokens`;
ses: WAV başlığından ya da FLAC STREAMINFO'sundan kesin süre) tek koşullu ifadeyle `usage_reservations`'a süreli bir satır olarak ayırır; sınırlar
kesinleşmiş kullanım + süresi dolmamış satırlardır. Üst çağrı ve kesinleştirme `waitUntil` ile istemci koparsa da
tamamlanır: gerçek kullanım ve maliyet yazılır, satır silinir. Üst çağrı istek gönderildikten sonra başarısız olursa
kullanıcıya bir şey yazılmaz, tahmini girdi maliyeti (ses tamamen gittiyse ses maliyeti) günlük harcamaya sayılır.
Worker kesinleştiremeden durursa satırın süresi dolar (LLM 15 dk, ses 20 dk): sınırlar onu yok sayar, günlük temizlik
tahmini maliyetini harcamaya ekleyip siler (`usage_reservations_expired` uyarısı). Toplantıda aynı anda tek ses isteği
işlenir; süren varken yenisi `409 transcription_in_progress` alır.

## Deneme kötüye kullanımı

Deneme hesap başına `TRIAL_MEETINGS` toplantı ya da `TRIAL_DAYS` gündür, hangisi önce dolarsa. Süre hesabın ilk deneme
toplantısıyla başlar (`users.trial_started_at`, ilk toplantıyla aynı işlemde yazılır); dolunca kullanılmamış toplantılar
da düşer (`402 trial_exhausted`, `trial_refused` logunda `reason: expired`) ve toplantı dışı yapay zekâ kapanır. Üç ek
engel vardır:

- **Kimlik deneme defteri** (`src/trialLedger.ts`): hesap silinince her giriş kimliği için (`trial-identity:<sağlayıcı>:<sub>`
  metninin `TRIAL_HASH_SECRET` ile HMAC özeti; kimlik açık saklanmaz) harcanan deneme sayısı, denemenin başladığı an
  ve Mac doğrulaması `trial_identity_ledger`'a yazılır. Aynı kimlikle yeniden açılan hesap bunları devralır
  (`users.carried_trial_meetings`, `users.trial_started_at`, `users.trial_device_verified_at`) ve IP sınırına yeni deneme hesabı olarak girmez.
  Defter o ayın (UTC) kullanımını da taşır (süre, token, toplantı dışı token; aynı ay için büyüğü): aynı ay içinde
  yeniden açılan hesap bunu `monthly_usage`'a devralır (süre `carried_seconds` olarak aylık süre sınırına eklenir),
  sonraki ay sıfırdan başlar; silip yeniden açarak aylık sınırlar sıfırlanamaz. Kullanımı olmayan, deneme harcamamış ve
  Mac doğrulamamış hesap için satır yazılmaz. Satır son güncellemeden 730 gün sonra silinir.
- **Mac başına deneme** (`src/deviceCheck.ts`, `DEVICECHECK_POLICY=required`): Apple DeviceCheck her Mac için iki bit
  saklar; sunucu cihaz kimliği görmez. `bit0` = "bu Mac bir hesaba deneme verdi" (`bit1` kullanılmaz, korunur).
  Denemesi henüz bir Mac'e bağlanmamış hesabın deneme toplantısı `deviceCheckToken` ister (`400 device_check_required`);
  `bit0` doluysa `403 trial_device_used`; boşsa Mac işaretlenir ve hesap doğrulanmış sayılır (sonraki deneme
  toplantıları jeton istemez). Apple 400 verirse `400 device_check_invalid`; 5xx/429/ağ hatası uyarıyla 3 kez denenir,
  sonra `502 upstream_unavailable`. Abonelik toplantısı ve denemesi bitmiş hesap DeviceCheck çağırmaz. `off` iken
  DeviceCheck hiç çağrılmaz.
- **IP başına yeni deneme hesabı**: `TRIAL_ACCOUNTS_PER_IP_PER_DAY` (IP'nin HMAC özeti, gün sonunda silinir).

App Attest (`APP_ATTEST_POLICY`) macOS'ta desteklenmediği için bugün cihaz sınırı vermez; kodu yerinde durur. Bu
yüzden davet programındaki cihaz denetimi (`sharesDevice`) de Mac'te eşleşmez (aşağıda "Davet programı").

## Davet programı

"Bir ay ver, bir ay al" (`src/referrals.ts`, `src/referralRewards.ts`, göç `0038_referrals.sql`):

- Abonelik erişimi olan hesap `GET /v1/referral` ile kişisel kodunu alır (8 karakter, rastgele, `0 1 I L O` yok).
- Hiç abone olmamış hesap kodla abone olur: istemci kodu `POST /v1/referral/validate` ile denetletir ve Checkout'a
  `referralCode` olarak geçirir. Sunucu kodu yeniden doğrular, Stripe'ta kuponu (yoksa) kendisi açar ve oturuma ekler:
  aylıkta `gistsmith_invite_first_month` (%100, bir kez: ilk ay ücretsiz), yıllıkta `gistsmith_invite_yearly_599`
  (5,99 $, bir kez). Kod aboneliğin `metadata.referral_code`'una yazılır.
- `invoice.paid`: kodla açılan aboneliğin ilk faturası `joined`; ilk sıfırdan büyük ödeme (aylıkta ikinci ay, yıllıkta
  ilk fatura) `qualified` ve 30 gün bekleme. Bu sürede iade (kısmi dahil) ya da itiraz gelirse ödül düşer.
- Günlük Cron günü gelen ödülleri verir: davet edenin Stripe müşterisine `-599` sent (USD) müşteri bakiyesi hareketi
  (`metadata.purpose=referral_reward`); Stripe sonraki faturalarından düşer. Müşteri bakiyesi seçildi çünkü plandan
  bağımsızdır, birden çok ödül birikir ve aboneliği değiştirmez. Çift ödül yok: satır durumu, idempotency anahtarı ve
  çağrıdan önce bakiye hareketlerinde aynı ödül araması.
- Ücretsiz ayında aboneliği biten (Stripe'ta `canceled`/`incomplete_expired`) arkadaşın daveti düşer
  (`void`/`canceled_before_payment`): davet edenin "bekleyen" sayısında ve tahmini ödül tarihinde kalmaz.
- Kötüye kullanım:
  - Kendi kodu `403 referral_self`. App Attest cihazını paylaşan hesaplar da `referral_self` alır (`sharesDevice`), ama
    App Attest macOS'ta desteklenmediği için bu denetim Mac'te hiç eşleşmez: Mac'te aynı bilgisayarda açılan yeni
    Google/Apple hesaplarını cihaz denetimi durdurmaz. Onları aşağıdaki kart denetimi ve açık davet sınırı karşılar.
  - Daha önce abonelik ya da ücretsiz erişim satırı olan hesap (ücretsiz erişimin süresi dolsa ya da yönetici kaldırsa
    da satır kalır) ya da aynı giriş kimliğiyle (hesap silinmiş olsa da; kimlik özeti 730 gün) daha önce davetle abone
    olmuş kimlik `409 referral_not_eligible`.
  - Kodun sahibi kod paylaşabilmeli: abonelik erişimi var ve kendisi davetin ücretsiz ilk ayında değil (ilk ücretli
    faturası ödenmeden kodu yoktur ve kodu `404 referral_invalid` alır): ücretsiz aylar hesaptan hesaba zincirlenemez.
  - Kart: kodla açılan aboneliğin ilk faturası ödenince (`invoice.paid`) aboneliğin varsayılan ödeme yönteminin kart
    parmak izi okunur ve `TRIAL_HASH_SECRET` ile HMAC özeti saklanır (göç `0040`; parmak izi açık saklanmaz). Kart davet
    edenin Stripe'ta kayıtlı kartlarından biriyse ya da davet edenin kendi davetindeki kartsa `void`/`self_card`, başka
    bir davette kullanılmışsa (herhangi bir davet eden) `void`/`card_reused`: ödül verilmez, arkadaşın Stripe'ta aldığı
    indirim geri alınmaz. Ödeme yöntemi kart değilse (ör. Link) denetim yapılamaz (`referral_join_without_card`
    uyarısı; yönetim panelinde "kart denetlenmedi").
  - Açık davet sınırı `REFERRAL_MAX_PENDING` (3): ödülü bekleyen (`joined`, `qualified`), son 24 saatte Checkout'a
    götürülen ve son 365 günde kart yüzünden düşen davetler sayılır; dolunca kod yeni arkadaşa `409
    referral_limit_reached` döner. Böylece tek kod ve tek kartla açılan hesaplar sınırsız ücretsiz ay alamaz.
  - Davet eden son 365 günde en çok 12 ödül (`capped`); doğrulama kullanıcı başına dakikada 10.

## Zamanlanmış temizlik

`wrangler.jsonc` → `triggers.crons` her gün 03:17 UTC'de `scheduled` işleyicisini çalıştırır (`src/cleanup.ts`). Silinenler:
süresi dolmuş ayırmalar (tahmini maliyeti harcamaya yazılarak), süresi dolmuş nonce'lar (Apple ve Google), süresi dolmuş
ya da kullanılmış cihaz meydan okumaları, süresi dolmuş ya da ailesi düşürülmüş yenileme jetonları (kullanılmış jeton,
önceki kuşak ve geçersiz yazılmış halef çalınma algılaması için süresi dolana dek kalır) ve jetonu kalmamış aileler, 90 günden eski Stripe olayları ve günlük harcama, bugünden eski deneme
başlangıçları, 2 günden eski kullanıcı günlük kullanımı, 13 aydan eski toplantılar (deneme toplantıları önce
`users.carried_trial_meetings`'e eklenir: deneme hakkı geri gelmez) ve aylık kullanım, 13 aydır kullanılmayan cihazlar,
180 günden eski raporlar (durumundan bağımsız), 730 gündür güncellenmemiş kimlik deneme defteri satırları ve hesabı
silinmiş davet edilenlerin davet satırları. Aynı Cron günü gelen davet ödüllerini de verir (`referral_rewards` adımı).
İndirme sayacı (gün başına tek satır, kişisel veri yok) silinmez. Silme tablo başına 1000 satırlık en çok 3 turdur; kalan
ertesi gün silinir (`cleanup_incomplete` uyarısı). Her adım ayrı denenir: biri başarısız olursa `cleanup_failed` alarmı
yazılır, diğerleri çalışır ve sonunda `CleanupFailedError` fırlatılır. Yerelde: `npx wrangler dev --test-scheduled`, sonra
`curl "http://localhost:8787/__scheduled?cron=17+3+*+*+*"`.

## İlk dağıtım (sahibin bir kez yapacakları)

1. `npx wrangler login`
2. `npx wrangler d1 create ainotepad-production` → çıkan `database_id`'yi `wrangler.jsonc` → `env.production` içine yaz.
3. `wrangler.jsonc` → `env.production`:
   - `routes`: `api.gistsmith.com` özel alan adı (gistsmith.com bölgesi aynı Cloudflare hesabında olmalı; dağıtımda
     DNS kaydı ve sertifika kendiliğinden kurulur). `workers_dev` ve `preview_urls` üretimde `false`'tur:
     Stripe webhook'u ve uygulamalar yalnızca `api.gistsmith.com`'u kullanmalı.
   - `vars`: `SITE_ORIGIN` (`https://gistsmith.com`), `APP_ATTEST_APP_IDS` (`TEAMID.com.senoldogan.AINotepad.hosted`),
     `STRIPE_PRICE_ID`, `GOOGLE_CLIENT_IDS` (Google Cloud Console → sitenin OAuth web istemcisi), `DMG_URL`,
     `PRICE_USD_MONTHLY` (Stripe fiyatıyla aynı), `REPORT_BYTES_PER_DAY`. `APPLE_CLIENT_IDS` hazırdır:
     `com.senoldogan.AINotepad.hosted` (abonelik uygulamasının paket kimliği) ve `com.senoldogan.AINotepad.web` (sitenin
     Apple ile giriş Services ID'si; bkz. `web/README.md`).
   - `ADMIN_IDENTITIES` önce boş kalır. Dağıtımdan sonra sitede kendi hesabınla giriş yap; kimliğin (`google:…` ya da
     `apple:…`) D1'de: `npx wrangler d1 execute ainotepad-production --remote --env production --command
     "SELECT provider || ':' || subject FROM auth_identities WHERE user_id = '<kullanıcı kimliği>'"` (kullanıcı kimliği
     giriş yanıtındaki `userId` ya da `admin_forbidden` uyarısındaki `userId`); onu yazıp yeniden dağıt.
4. Yukarıdaki gizli değerleri `wrangler secret put … --env production` ile gir.
5. `npm run migrate:production`
6. `npm run deploy`
7. Stripe panelinde webhook uç noktası: `https://api.gistsmith.com/v1/billing/webhook`, olaylar
   `customer.subscription.created|updated|deleted|paused|resumed`, `customer.deleted`, `charge.refunded`,
   `charge.dispute.created`, `invoice.paid` (kopya aboneliğin geç ödemesi ve davet ödülü); imza sırrını `STRIPE_WEBHOOK_SECRET` yap.
   Davetin kart denetimi için webhook'un anahtarı abonelikleri (`default_payment_method` genişletilmiş), ödeme
   yöntemlerini ve müşterinin ödeme yöntemleri listesini okuyabilmelidir (kısıtlı anahtarda "Payment Methods: Read"). Canlıya geçerken anahtar (`sk_live_`/`rk_live_`)
   ve canlı moddaki webhook birlikte değişmeli: olayın modu anahtarınkiyle uyuşmazsa webhook `500` ve
   `stripe_mode_mismatch` alarmı verir; anahtarın modu `GET /v1/admin/stats` → `stripe.mode`'dadır.
   Stripe Tax'i ve Müşteri Portalı'nı panelden aç.
8. `curl https://api.gistsmith.com/v1/health` → `{"status":"ok"}`
9. Önerilen: Cloudflare panelinde `api.gistsmith.com` için bir WAF hız sınırı kuralı. Workers Free planının hesap
   genelindeki günlük 100 000 istek ve D1 yazma kotası Worker'ın kendi hız sınırlarından önce tükenebilir (fatura değil,
   kesinti riski).

## Uçlar

| Uç | Kimlik | Not |
|---|---|---|
| `GET /v1/health` | — | |
| `POST /v1/auth/apple` | — | `{identityToken, nonce}`; Apple'a `sha256hex(nonce)` verilir; e-posta saklanmaz |
| `POST /v1/auth/google` | — | `{identityToken, nonce}`; Google'a `sha256hex(nonce)` verilir. `iss` `https://accounts.google.com` ya da `accounts.google.com`, `aud` ∈ `GOOGLE_CLIENT_IDS`, RS256, nonce tek kullanımlık. Kimlik `google:<sub>`; e-posta saklanmaz. Apple hesabıyla otomatik bağlama yoktur (ayrı kullanıcı). Oturum yanıtı ve deneme kuralları Apple ile aynı |
| `POST /v1/auth/refresh`, `/v1/auth/logout` | — | `{refreshToken}`; dönen jeton, yeniden kullanım aileyi düşürür; yalnızca hemen önceki jeton 10 dk içinde yeniden sunulursa ve halefi hiç kullanılmadıysa (yanıtı kaybolan yenileme) yeni çift verilir; kaybolan halef geçersiz işaretlenir, sonradan sunulursa tüm aile düşer. Dönüşte ailede en son kullanılmış jeton, ondan önceki ve geçersiz işaretli halefler dışındaki kullanılmış jetonlar silinir; kalanlar süresi dolana dek tutulur |
| `GET /v1/me` | Bearer | plan, etkin kalan deneme (isteğe bağlı `x-device-key-id` ile hesap ve cihazın küçüğü; süre dolduysa 0), `trialDays`, `trialEndsAt` (ilk deneme toplantısı + `TRIAL_DAYS`, ISO 8601; deneme başlamadıysa ya da abonelikte `null`), aylık saat ve sınır, `monthlyResetsAt` (aylık sınırların sıfırlandığı an: sonraki UTC ayının başı), toplantı dışı yapay zekâ hakkı (`accountTokensUsed`, `accountTokensCap`, `accountTokensPeriod`: abonede `month` ve `MONTHLY_ACCOUNT_TOKEN_CAP`, denemede `day` ve `TRIAL_ACCOUNT_DAILY_TOKENS`; `accountTokensResetsAt`), `liveEngine` (`deepgram` / `whisperkit`, bkz. "Deepgram canlı metni"), abonelik erişimi (`active` / `grace` / `none`) ve planı (`subscription.plan`: `monthly` / `yearly`; fiyatı tanınmayan eski abonelikte `null`) |
| `DELETE /v1/me` | Bearer | hesabı siler (GDPR), `204`: önce Stripe'taki bitmemiş abonelikler hemen iptal edilir (başarısızsa hiçbir şey silinmez, `502`); sonra kimlikler, oturumlar, cihazlar, toplantılar, kullanım, abonelik ve Stripe müşteri eşlemesi, deneme kayıtları ve hesabın raporları tek işlemde silinir; aynı işlemde önce her kimliğin deneme defteri satırı yazılır (harcanan deneme ve Mac doğrulaması, kimliğin HMAC özetiyle; deneme harcanmadıysa yazılmaz) (raporlar serbest metin ve e-posta taşıyabildiği için bağı kaldırılmaz, silinir; jetonsuz gönderilmiş raporlar hesaba bağlanamaz, 180 günde silinir). Bugünkü deneme başlangıcı IP özeti başına günlük sayaçta hesap bağı olmadan kalır. Stripe'taki müşteri ve faturalar vergi kayıtları için Stripe'ta kalır. Tekrarı (aynı jetonla) `204` |
| `POST /v1/device/challenge` | Bearer | `{purpose: "attest" \| "assert"}` |
| `POST /v1/device/attest` | Bearer | `{keyId, attestation, challenge}` (base64) |
| `POST /v1/meetings/start` | Bearer | `{device?: {keyId, assertion, clientData}, deviceCheckToken?: <base64>, clientRef?, deferred?}`; clientData = `{"action":"meetings.start","challenge":…}`; `deviceCheckToken` (`DCDevice.generateToken()`) denemesi henüz bir Mac'e bağlanmamış hesabın deneme toplantısında gerekir (bkz. "Deneme kötüye kullanımı"); `clientRef` (`[A-Za-z0-9._-]{1,64}`) istemcinin kayıt kimliğidir: aynı kimlikle yinelenen başlatma aynı oturumu döndürür; `deferred: true` sonradan işlenen kayıttır, açık toplantıyı kapatmaz. Yeni hesabın ilk denemesi IP başına günde `TRIAL_ACCOUNTS_PER_IP_PER_DAY` (üretimde 10); kullanıcı başına günde en çok 20 başlatma; yeni toplantı açık olanı ek süresiz kapatır, reddedilen başlatma açık toplantıya dokunmaz ve sayılmaz |
| `POST /v1/meetings/{id}/end` | Bearer | |
| `POST /v1/meetings/{id}/reprocess` | Bearer | gövde yok → `{meetingId, usableUntil, reprocessesLeft}`; bitmiş toplantıyı `MEETING_GRACE_MINUTES` boyunca yeniden yazıya dökme ve not için açar (toplantı başına en çok 2 kez, `409 reprocess_limit_reached`). Aboneliği ya da denemesi olmayan hesap yalnızca bitişten sonraki 7 gün içinde (`402 subscription_required`). Harcama tavanı doluysa hak harcanmadan `503 spend_ceiling_reached`; deneme toplantısında deneme tavanı ya da ElevenLabs deneme durağı doluysa `503 trial_capacity_reached`. Tanımlar `src/meetings.ts` → `reprocessMeeting` |
| `POST /v1/live/deepgram-token` | Bearer + `x-meeting-id` | kısa ömürlü Deepgram jetonu; bkz. "Deepgram canlı metni" |
| `POST /v1/llm/messages` | Bearer, isteğe bağlı `x-meeting-id` | zorunlu `effort: "low" \| "medium"` + Anthropic Messages alt kümesi; `thinking` yok; `stream: true` ise SSE. `x-meeting-id` varsa (kayıt sırasındaki çeviri, "Ne kaçırdım?", soru) toplantı açık ya da ek sürede olmalı, toplantı bütçesinden düşer, çağrı başı `LLM_MAX_TOKENS`. Yoksa hesap çağrısıdır (Sor, notu yeniden yazma, düzenleme, paylaşım çevirisi, görev aracı): erişimi olan abonelik ya da ilk toplantıyla başlamış (DeviceCheck `required` iken Mac'e bağlanmış), bitmemiş deneme gerekir (deneme hiç başlamadıysa `403 trial_not_started`, bittiyse `402 subscription_required`), çağrı başı daha küçük `LLM_ACCOUNT_MAX_TOKENS`; aboneliği olmayan kullanıcıda bu çağrılar ayrıca günlük `TRIAL_ACCOUNT_DAILY_TOKENS` (300 K; türetme `wrangler.jsonc`'ta) ile sınırlıdır (`429 daily_cap_reached`), abonede aylık `MONTHLY_ACCOUNT_TOKEN_CAP` (1,5 M) ile (`403 monthly_cap_reached`). Her iki durumda kullanıcı başına aylık (6,5 M) ve günlük (3 M) token sınırı ve harcama tavanı. Akışsız çağrı 120 sn, akışın ilk baytı 30 sn zaman aşımlıdır |
| `POST /v1/transcribe` | Bearer + `x-meeting-id` | gövde 16 kHz mono 16 bit FLAC (`Content-Type: audio/flac`; uygulamanın gönderdiği biçim) ya da ham PCM WAV (`audio/wav`; FLAC'tan önceki sürümler), `Content-Length` zorunlu; başka tür `415`. FLAC'ta `fLaC` imzası ve ilk blok STREAMINFO olmalı, 16 kHz / mono / 16 bit dışı biçim, toplam örneği 0 olan ya da boyutu STREAMINFO'daki örnek sayısına sığmayan (PCM boyutunun %1 fazlası + 4 KB) dosya `400 invalid_body`; dosya ElevenLabs'e `audio.flac` olarak iletilir; `?language_code=&diarize=`; anahtar terimler `x-keyterms` başlığında: UTF-8 JSON dizgi dizisinin dolgusuz base64url'i (en çok `TRANSCRIBE_MAX_KEYTERMS`; terim <50 karakter, ≤5 kelime, `<>{}[]\` yok; değerler loglanmaz). Yayımlanmış 0.1.4 uygulaması için tekrar eden `?keyterms=` de kabul edilir (ikisi birlikte `400`). Süre WAV başlığından (veri baytı / bayt hızı) ya da FLAC STREAMINFO'sundan (toplam örnek / 16000) kesin hesaplanıp önceden ayrılır; toplantının sesi en çok toplantının süresi kadar; toplantıda aynı anda tek istek (`409 transcription_in_progress`). ElevenLabs isteği 15 dk zaman aşımlıdır. Uzun toplantıda ses parçalar halinde sırayla gönderilir (FLAC: en çok 95 MB ve 60 dk; eski WAV: 95 MB, ~49 dk; parçalar 1 dk örtüşür) |
| `POST /v1/billing/checkout` | Bearer | `{plan: "monthly" \| "yearly", referralCode?}` (katı; kod plansız gönderilemez) → `{url}`. Plansız istek aylıktır: yalnızca eski istemciler için (uygulama ≤ 0.1.5 gövdesiz, eski site `{}`). Kod verilirse `POST /v1/referral/validate` ile aynı denetim ve hatalar; planın davet kuponu eklenir. Bitmemiş abonelik varken (`active`, `trialing`, `past_due`, `unpaid`, `incomplete`, `paused`; ek süre geçmiş olsa da; yerel satırda ya da Stripe'taki listede) `409 subscription_exists`, istemci Portal'ı açar; süren ücretsiz erişimde Stripe'a gitmeden `409 complimentary_subscription` |
| `POST /v1/billing/portal` | Bearer | `{url}`: Stripe Müşteri Portalı; süren ücretsiz erişimde Stripe'a gitmeden sitedeki hesap sayfası (`<SITE_ORIGIN>/account`); Stripe müşterisi yoksa `402 subscription_required` |
| `GET /v1/referral` | Bearer | `{enabled, code, inviteUrl, joined, rewarded, pending, nextRewardAt, complimentary, rewardsLeftThisYear, rewardsPerYear, rewardUsd, holdDays}`; `code` yalnızca program açık, abonelik erişimi var ve hesap davetin ücretsiz ilk ayında değilken (ilk istekte üretilir); `nextRewardAt` bekleyen ödülün en yakın tahmini tarihi (ücretsiz aydaki arkadaşta yenilenecek aboneliğin ilk ücretli faturası + 30 gün, ödeme alınmışsa kesin tarih) ya da null; `complimentary` ücretsiz erişimde true (ödül uygulanmaz) |
| `POST /v1/referral/validate` | Bearer | `{code}` → `{code}` (normalize: boşluk ve tire atılır, büyük harf). `404 referral_invalid`, `403 referral_self`, `409 referral_not_eligible`, `409 referral_limit_reached`, `503 referral_unavailable` (bkz. "Davet programı"); kullanıcı başına dakikada 10 |
| `POST /v1/billing/webhook` | Stripe imzası | olayın anlık görüntüsüne değil Stripe'taki güncel duruma güvenilir: müşterinin abonelikleri listelenir, kullanıcı başına tek geçerli abonelik yazılır (yaşayanlardan erişimi en yüksek, eşitse en eski). Yaşayan ikinci abonelik alarmla iptal edilir; tanınmayan müşterinin yaşayan aboneliği iptal edilir. `past_due` ek süresi (`PAST_DUE_GRACE_DAYS`) `past_due`'ya geçişten sayılır. `customer.deleted` eşlemeyi siler; `charge.refunded` alarm; `charge.dispute.created` alarm ve aboneliği hemen iptal. Hesap silinirken müşterinin açık Checkout oturumları da sona erdirilir |
| `POST /v1/reports` | İsteğe bağlı Bearer | `{kind, message?, email?, appVersion?, os?, payload?, turnstileToken?}` → `202 {}`. `contact` (site): `message` (≤5000), `email` (≤254) ve `turnstileToken` zorunlu, Turnstile doğrulanır. `feedback`: `message` zorunlu. `crash`: `payload` zorunlu (JSON nesnesi, ≤64 KB, aşarsa `413`; MetricKit ise listede kısa imza). `appVersion` ≤40, `os` ≤80. Türe ait olmayan alan reddedilir (ör. `feedback` + `payload`, `crash` + `turnstileToken`). Jeton varsa geçerli olmalı (`401`), rapor hesaba bağlanır; jetonsuz `feedback`/`crash` (hesapsız geliştirici sürümü ve iPhone) kabul edilir ama birlikte tür bütçesinin en çok dörtte birini kullanır. Gövde ayrıştırmadan önce en çok 160 KB (`413`); IP başına 5/dk, hesap başına günde 20, tür başına günde `REPORT_BYTES_PER_DAY` bayt (`429 daily_cap_reached`) |
| `GET /v1/download/mac/version` | — | `{version}`: DMG ile aynı sürümün Sparkle akışından (`APPCAST_URL`) okunan sürüm numarası (sitedeki indirme sayfası); `Cache-Control: public, max-age=300`, D1'e dokunmaz |
| `GET /v1/download/mac` | — | `?src=<home-hero \| home-cta \| download-page \| account>` (yoksa `direct`, tanınmayan `other`) → `302` → `DMG_URL`; ağ başına günde bir indirme sayılır: UTC gün toplamı ve kaynak + Referer alan adı sayacı (`download_sources`; yol ya da tam adres değil). Tekilleştirme için ağın gün ile HMAC özeti ertesi güne dek tutulur; tekrar indirme D1'e yazmaz. Sayaç yazılamazsa yine yönlendirir (`download_count_failed` uyarısı) |
| `GET /v1/admin/stats` | Bearer + yönetici | indirme, kullanıcı, deneme, abonelik (plan başına yenilenecek sayılar; MRR = aylık × `PRICE_USD_MONTHLY` + yıllık × `PRICE_USD_YEARLY` / 12), davet sayaçları (nedene göre düşen davetler dahil), toplantı, harcama, token ve açık rapor özetleri; 30 günlük seriler (UTC, eskiden yeniye, boş gün 0). Tanımlar `src/admin.ts` → `adminStats` |
| `GET /v1/admin/insights` | Bearer + yönetici | sorunlar (son 7 ve 30 gün: deneme kapasitesi ve harcama tavanı retleri, koda göre retler, servise göre üst servis hataları, 5xx), son 30 günün hunisi (indirme → hesap → ilk toplantı → ilk not → ≥ 3 toplantı → abone → davetle abone → iptal), indirme kaynakları ve Referer alan adları, Stripe iptal nedenleri, davet özeti (son 30 günde Checkout, katılım, ilk ödeme, ödül, nedene göre düşen davetler; şu an ücretsiz aydakiler; en çok davet edenler). Tanımlar `src/adminInsights.ts` |
| `GET /v1/admin/operations` | Bearer + yönetici | açık ve bitirilmemiş toplantılar, takılı ayırmalar, kesinleşmemiş Deepgram tahminleri, Stripe olayları (son olay, 24 saat, 7 günün türleri) ve son çökmeler. Tanımlar `src/adminOps.ts` |
| `GET /v1/admin/users` | Bearer + yönetici | `?q=<kimlik öneki>&segment=&provider=&cursor=`; `segment`: `subscribed`, `past_due`, `canceled`, `trial`, `free`, `invited` (davet koduyla abone olmuş) ya da bırakma kesimleri `no_meeting`, `trial_ended`, `inactive` (7 gündür toplantı yok), `failed` (toplantısında istek başarısız). Öğede `invite`: `invited` / `free_month` (davetin ücretsiz ilk ayında) / `null`. Tanımlar `src/adminUsers.ts` |
| `GET /v1/admin/users/{id}` | Bearer + yönetici | hesabın ayrıntısı: özet, Mac doğrulaması, Stripe müşterisi, son iptal nedeni, bu ayın kullanımı, toplantılar (en çok 100), raporlar (en çok 20), kullandığı davet (`invitedBy`: davet eden, kod, durum ve düşme nedeni, ücretsiz ayda mı, kart denetlendi mi, zamanlar), davetleri (`invites`: kod, sayaçlar, tahmini ödül tarihi, arkadaşlar) ve zaman çizelgesi (davet olayları dahil). Tanımlar `src/adminUsers.ts` |
| `POST /v1/admin/users/{id}/complimentary` | Bearer + yönetici | `{grant: true, until?: <ISO 8601 tarih ya da zaman>}` ücretsiz tam erişim verir (yoksa süresiz; varsa süresini değiştirir), `{grant: false}` süren ücretsiz erişimi şimdi bitirir (satır kalır: hesap yeniden abone olabilir, davet kodu kullanamaz) → kullanıcının ayrıntısı. Bitmemiş Stripe aboneliği varsa `409 subscription_exists`; süren ücretsiz erişim yoksa kaldırma `404`. Tanımlar `src/complimentary.ts` |
| `GET /v1/admin/reports` | Bearer + yönetici | `?kind=&status=&before=<ms>` → `{items: [{id, kind, status, createdAt, userId, email, appVersion, os, summary}], nextBefore}`; sayfa 50, yeniden eskiye, `createdAt` ISO 8601, `nextBefore` ms ya da son sayfada `null` |
| `GET /v1/admin/reports/{id}` | Bearer + yönetici | `{id, kind, status, createdAt, userId, email, appVersion, os, message, payload}` |
| `POST /v1/admin/reports/{id}` | Bearer + yönetici | `{status: "open" \| "done"}` → `204` |
| `GET /v1/admin/blog/posts` | Bearer + yönetici | `{today, posts: [{slug, title, description, author, published, updated, cover, draft, status, sha}]}`: depodaki tüm yazılar, yeniden eskiye (aynı gün başlığa göre); `status` `draft` / `scheduled` (`published` > `today`, UTC) / `live`; `updated` ve `cover` yazılmamışsa `null`; `sha` dosyanın GitHub sürümü. Bkz. "Blog yayını" |
| `GET /v1/admin/blog/posts/{slug}` | Bearer + yönetici | listedeki alanlar + `body` (Markdown); yoksa `404` |
| `PUT /v1/admin/blog/posts/{slug}` | Bearer + yönetici | `{title, description, author, published, updated, cover, draft, body, sha}` (katı; `updated` ve `cover` her istekte, yoksa `null`) → yeni yazıda `201`, güncellemede `200` ve yazının kayıttan sonraki hâli. Yeni yazıda `sha: null` (dosya varsa `409 blog_post_exists`); güncellemede açılan sürüm (dosya değişmiş ya da silinmişse `409 blog_conflict`). Kurallar ve dosya biçimi: "Blog yayını"; ihlal `400 invalid_body`, geçersiz kısa ad `400 bad_request` |
| `DELETE /v1/admin/blog/posts/{slug}?sha=` | Bearer + yönetici | `204`: yazı ve görsel klasörü tek commit'te silinir; yoksa `404`, sürüm uyuşmazsa ya da dal sürekli ilerlerse `409 blog_conflict`, `sha` yoksa `400` |
| `PUT /v1/admin/blog/posts/{slug}/images/{name}` | Bearer + yönetici | `{data}` (katı; WebP'nin standart base64'ü, en çok 600 KB, genişlik en çok 1600 px) → `201 {path, sha, bytes, width, height}` (`path`: `/blog/<slug>/<name>`). Ad `^[a-z0-9-]+\.webp$` (değilse `400 bad_request`); WebP değilse `415 unsupported_media_type`, büyükse `413 payload_too_large`, genişse `400 invalid_body`; yazı yoksa `404`, ad kullanılmışsa `409 blog_image_exists`. Bkz. "Blog yayını" |

Hatalar her zaman `{"error": {"code", "message"}}` biçimindedir; yönetici olmayan kullanıcının yönetici isteği düz
`403 forbidden` döner (gövdede kimlik yok).
Günlük harcama tavanı aşılınca toplantı başlatma ve her vekil çağrısı `503 spend_ceiling_reached` döner; günlük deneme
harcaması tavanı aşılınca deneme harcaması açan her istek (yeni deneme toplantısı, denemedeki hesap çağrısı, açık ya da
yeniden açılmış deneme toplantısının yapay zekâ ve yazıya dökme çağrıları, deneme toplantısını yeniden işleme)
`503 trial_capacity_reached` döner. İki tavanın alarmı günde bir kez yazılır; retlerin sayısı yönetim panelindedir
(`ops_events`). Site kaynağı
(`SITE_ORIGIN`) CORS'u yalnızca site uçlarında (`src/app.ts` → `webRoutes`: `/v1/health`, `/v1/download/mac/version`,
giriş, yenileme ve çıkış, `/v1/me`, ödeme ve Portal, `/v1/referral`, `/v1/referral/validate`, `/v1/reports`) ve yönetici
uçlarında alır; `GET /v1/download/mac/version` dışında her yanıt `Cache-Control: no-store` taşır.

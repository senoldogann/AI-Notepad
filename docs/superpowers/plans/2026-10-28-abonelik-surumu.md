# Abonelik sürümü — web sitesi, hesaplar, ödeme, barındırılan servisler

Kullanıcı onayı (2026-10-28):
- Hibrit maliyet modeli, aylık 5,99 $ (2026-10-28: 2,99 $'da aylık sınıra kadar kullanan abonede zarar ediliyordu).
- Altyapı Cloudflare.
- Giriş Apple ile giriş ve e-posta bağlantısıyla.
- Alan adı sonra seçilecek; o zamana dek `*.pages.dev` / `*.workers.dev`.

## Hedef

Herkes web sitesinden DMG indirip anahtarsız kullanır.
- İlk 3 toplantı ücretsizdir.
- Sonrası Stripe ile aylık 5,99 $ aboneliktir. Tutar Stripe'taki fiyattadır (`STRIPE_PRICE_ID`); kodda geçmez.
- Not, çeviri ve konuşmacı ayırma bizim anahtarlarımızla bizim sunucumuz üzerinden yapılır. Anthropic için yalnızca Claude Haiku 5.5, ayrıca ElevenLabs.

**Bugünkü uygulama hiç değişmez.**
- Kendi anahtarları, tüm modeller ve tüm motorlarıyla geliştirici sürümü olarak kalır.
- Abonelik sürümü ayrı bir Xcode hedefidir: ayrı paket kimliği ve derleme bayrağı `HOSTED_EDITION`.
- İkisi aynı Mac'te yan yana durabilir.

## Maliyet modeli (hibrit)

| Kalem | Nerede | Yaklaşık maliyet |
|---|---|---|
| Canlı metin | Mac'te WhisperKit (ücretsiz, internetsiz) | 0 |
| Toplantı sonu konuşmacı ayırma ve son metin | ElevenLabs Scribe (toplu) | ~0,22 $ / saat |
| Not, canlı çeviri, "Ne kaçırdım?", Sor | Claude Haiku 5.5 | ~0,02 $ / saat |

Hedef: toplantı saati başına ~0,25 $.
- Adil kullanım sınırı ayda 10 saattir. Sınıra gelen kullanıcıya açık bir mesaj gösterilir; ay başında sıfırlanır.
- Deneme hakkı 3 toplantı, toplantı başına en çok 90 dakika.
- Marj: 5,99 $'dan KDV (%25,5) ve Stripe payı (~%2,9 + 0,30 $) düşünce ~4,3 $ kalır; aylık 10 saatin tamamını kullanan
  abonenin maliyeti ~2,9 $ (saat başı ~0,29 $, terim listesi dahil). En kötü durumda da kâr kalır.
- Deepgram bu sürümde kullanılmaz: korunacak bir anahtar ve bir maliyet kalemi daha az.
- Fiyatlar Deepgram, ElevenLabs ve Anthropic'in resmi sayfalarından doğrulanmalıdır.

## Güvenlik ilkeleri

1. **Anahtarlar istemciye hiç girmez.** Anthropic ve ElevenLabs anahtarları ile Stripe gizli anahtarı yalnızca Cloudflare Workers gizli değişkenlerindedir (`wrangler secret`).
   - Repoda, logda ya da hata mesajında anahtar olmaz.
   - Kod açık kaynaktır; güvenlik gizliliğe değil, hesaplara ve kotalara dayanır.
2. **Kimlik.**
   - Apple ile giriş: kimlik jetonu Apple'ın JWKS'iyle doğrulanır; `aud` ve `iss` denetlenir, nonce kullanılır.
   - Google ile giriş: Google kimlik jetonu; nonce uygulamanın deneme başına ürettiği ham değerin SHA-256'sıdır.
   - Oturum: kısa ömürlü erişim jetonu (15 dk, imzalı) ve dönen yenileme jetonu (karma olarak saklanır; yeniden kullanılırsa tüm oturumlar düşer).
   - Uygulama jetonları Anahtar Zinciri'nde tutar.
3. **Cihaz doğrulama.**
   - Apple App Attest (`DCAppAttestService`) ile uygulamanın gerçek ve imzalı olduğu doğrulanır.
   - Deneme hakkı hesap ve cihaz başınadır; yeni hesap açmak hakkı sıfırlamaz.
   - App Attest'in Developer ID dağıtımında ve macOS'ta desteği uygulamadan önce doğrulanmalıdır. Desteklenmiyorsa DeviceCheck ya da cihaz anahtarı yedeği için kullanıcıdan karar alınır.
4. **Vekil sunucu dar ve kotalıdır.**
   - Genel bir LLM vekili değildir. Her çağrı açık bir "toplantı oturumuna" bağlıdır: oturum açılınca deneme ya da abonelik hakkı düşer.
   - Model sunucuda sabittir: `claude-haiku-5-5`. İstemcinin model alanı yok sayılır.
   - `max_tokens`, girdi boyutu, istek sayısı ve toplantı başına token bütçesi sunucuda sınırlanır.
   - ElevenLabs'e giden sesin süresi sunucuda ölçülür ve aylık saatten düşer.
5. **Kötüye kullanıma karşı.**
   - Cloudflare hız sınırı: IP ve kullanıcı başına.
   - Giriş ve e-posta uçlarında Turnstile.
   - Gövde boyutu sınırı ve sıkı CORS.
   - Günlük toplam harcama tavanı: aşılırsa yeni oturum açılmaz, uyarı gider.
   - Kullanıcı başına anormallik alarmı.
6. **Ödeme.**
   - Stripe Checkout ve Müşteri Portalı kullanılır; kart bilgisi bize hiç gelmez.
   - Webhook imzası doğrulanır ve olaylar tek kez işlenir (olay kimliği saklanır).
   - Abonelik durumu yalnızca webhook'tan yazılır.
   - AB KDV'si Stripe Tax ile.
7. **Gizlilik.**
   - Ses ve metin sunucuda saklanmaz: yalnızca iletilir ve kotası sayılır.
   - Loglarda içerik yoktur, yalnızca süre, token ve durum.
   - Gizlilik politikası ve kullanım şartları sitede yer alır (GDPR, alt işleyenler: Anthropic, ElevenLabs, Cloudflare, Stripe).

## Parçalar

1. **`server/`: Cloudflare Worker (TypeScript).**
   - D1 tabloları: kullanıcılar, cihazlar, oturumlar, toplantı oturumları, kullanım, abonelikler, işlenmiş Stripe olayları.
   - Uçlar: giriş, jeton yenileme, cihaz doğrulama, hak durumu, toplantı oturumu, `/v1/llm` (Haiku vekili), `/v1/transcribe` (ElevenLabs vekili), Stripe Checkout, Portal ve webhook.
   - Testler: `wrangler` ve Vitest Workers havuzu; gerçek Stripe test modu ve gerçek API çağrıları ortam değişkeniyle.
2. **`web/`: Cloudflare Pages sitesi.**
   - Tasarım yönü C: beyaz zemin, durağan pastel film gradyanları, kapak altında başlık, ses dalgası, Inter yazı tipi.
   - Sayfalar: ana sayfa, fiyat, indir (DMG ve sürüm notları), giriş, hesap (abonelik ve Stripe Portalı), gizlilik, şartlar.
   - Türkçe ve İngilizce.
3. **Mac abonelik sürümü (`AINotepadHosted` hedefi).**
   - Giriş ekranı ve deneme sayacı ("3 toplantıdan 2'si kaldı").
   - Abonelik düğmesi Stripe Checkout'u tarayıcıda açar.
   - Yapay zekâ sağlayıcısı olarak barındırılan servis kullanılır. Anahtar, model ve motor ayarları gizlidir; canlı metin WhisperKit'tir.
   - Güncellemeler Sparkle ile, aynı yayın akışından.
4. **Yayın.** `release.sh` iki DMG üretir (geliştirici ve abonelik sürümü). Site abonelik DMG'sini sunar.

## Kullanıcının yapacakları

1. Cloudflare hesabı.
2. Stripe hesabı (işletme bilgileri, Stripe Tax).
3. Apple Developer'da Apple ile giriş servis kimliği ve anahtarı, App Attest yeteneği.
4. E-posta gönderim servisi (Resend ya da Cloudflare Email).
5. Alan adı.

Gizli değerler sohbete yazılmaz; güvenli girişle istenir.

## Sıra

1. Sunucu: kimlik, haklar, vekil ve Stripe (test modu). Testler ve güvenlik incelemesi.
2. Mac abonelik sürümü (sunucunun yerel ve test ortamına karşı).
3. Web sitesi.
4. Uçtan uca test: Stripe test kartı ile deneme → abonelik → kota.
5. Hesaplar bağlanır, alan adı alınır, yayın yapılır.

## Durum

- [x] 1. Sunucu: kimlik, haklar, vekil, Stripe (test modu); güvenlik incelemesi ve düzeltmeleri (PR #66), CI (PR #68).
- [x] 2. Mac abonelik sürümü (`AINotepadHosted`, `App/Hosted`, `#if HOSTED_EDITION`).
  - Paket kimliği `com.senoldogan.AINotepad.hosted`; sunucunun `APPLE_CLIENT_IDS`'i bu kimlik ve web Services ID
    `com.senoldogan.AINotepad.web`. Kendi veri klasörü (`~/Library/Application Support/AINotepad Hosted`, Info.plist
    `AINotepadDataFolderName`), kendi UserDefaults alanı (paket kimliği) ve Anahtar Zinciri servisi (`AINotepadHosted`).
  - Ses sunucuya 16 kHz mono 16 bit WAV parçaları (≤95 MB, ~49 dk) halinde gider (sunucu sıkıştırılmış sesin süresini
    en kötü bit hızıyla tahmin eder).
  - Kayıt sırasındaki yapay zekâ (çeviri, "Ne kaçırdım?", soru) ve kaydın hemen ardındaki not toplantı bütçesinden;
    Sor, notu yenileme, tekrar işleme, düzenleme, paylaşım çevirisi ve görev aracı her zaman, toplantısız (abonelik ya da
    kalan deneme; kullanıcının günlük/aylık sınırı, `LLM_ACCOUNT_MAX_TOKENS`).
  - Süre sınırından 5 dk önce panelde ve adada uyarı; sınırda kayıt bitirilip normal işlenir.
  - Giriş Apple ile (uygulamada) ya da Google ile; e-posta girişi kaldırıldı. Google arayüzü sitededir: uygulama
    `/sign-in?app=1&nonce=<sha256hex(ham)>` açar, site `com.senoldogan.ainotepad.hosted://auth/google#idToken=…` ile
    döner, uygulama `POST /v1/auth/google` `{identityToken, nonce: ham}` gönderir (ham nonce bellekte, tek kullanımlık,
    10 dk).
  - Geri bildirim ve çökme raporları (iki sürüm ve iPhone) `POST /v1/reports`'a gider; GitHub'a bağlantı yok.
  - **Yayından önce:** abonelik sürümünün kendi Sparkle akışı (appcast) ve imza anahtarı gerekir; o zamana dek
    güncelleme kapalıdır (geliştirici akışı bu uygulamaya geliştirici DMG'sini kurardı).
- [x] 3. Web sitesi (PR #80).
- [ ] 4. Uçtan uca test (Stripe test kartı).
  - [x] Site, üretim sunucusuna karşı (2026-10-29): Apple ile giriş → deneme 3/3 → Checkout (4242) → webhook → abonelik
    etkin → Portal'dan iptal (sona eriyor, dönem sonuna dek erişim) → hesap silme (Stripe aboneliği iptal, D1'de satır
    kalmadı).
  - [ ] Mac abonelik uygulaması, üretim sunucusuna karşı gerçek toplantı (deneme sayacı, çeviri, not, yazıya döküm).
- [ ] 5. Hesaplar, alan adı, yayın.
  - Bağlı (test modu): Worker `ainotepad-server-production` (`*.senoldogan0233.workers.dev`), D1
    `ainotepad-production` (AB yargı alanı), Pages projesi `ainotepad` (ainotepad.pages.dev), Turnstile parçacığı
    `ainotepad`, Apple Services ID `com.senoldogan.AINotepad.web` (birincil App ID `.hosted`), Stripe test ürünü ve
    5,99 $/ay fiyatı (KDV hariç, Stripe Tax), müşteri portalı ve webhook (API sürümü SDK'nınkiyle aynı). Anthropic ve
    ElevenLabs (yalnızca Speech to Text izinli) üretim anahtarları Worker gizli değerlerinde.
  - Stripe test ortamı başka bir projeyle (HouseStory) paylaşılıyor: Checkout ve Portal'da işletme adı "HouseStory"
    görünür. Canlıda hesabın genel adı görünür; testte ayrı bir Stripe sandbox'ı daha temiz olur.
  - **Yayından önce:** alan adı (site, Worker, Apple Services ID ve Turnstile alan adları birlikte değişir); Stripe
    canlı mod (canlı ürün, fiyat, webhook ve anahtar); abonelik sürümünün Sparkle akışı; yasal metinlerdeki işletmeci bilgileri ve hukuki inceleme.

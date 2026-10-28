# AI-Notepad web sitesi

Cloudflare Pages'te durağan site: tanıtım, fiyat, indirme, giriş (Apple ve e-posta bağlantısı), hesap ve yasal
taslaklar, Türkçe (`/tr/…`) ve İngilizce (`/en/…`). Abonelik sunucusuyla (`../server`) tarayıcıdan konuşur.

**Yığın:** Astro (durağan çıktı) ve katı TypeScript. Sayfalar derlemede HTML olur; tarayıcıya yalnızca giriş, e-posta
bağlantısı, hesap ve dil yönlendirmesi için küçük betikler gider. Satır içi betik ve stil yoktur (CSP `'unsafe-inline'`
istemez). İzleyici, analiz ve CDN yazı tipi yoktur; Inter uygulamanın dosyasından (`../App/Fonts`) küçültülüp sunulur.

## Geliştirme

```bash
cd web
npm ci
npm run dev           # http://localhost:8788, yerel yapılandırma (API: http://127.0.0.1:8787)
npm run typecheck
npm run build         # yayın yapılandırmasıyla dist/
```

Yerel uçtan uca deneme (gerçek sunucu, gerçek Turnstile deneme anahtarı):

```bash
# 1. sunucu: server/README.md'deki gibi .dev.vars (TURNSTILE_SECRET_KEY=1x0000000000000000000000000000000AA)
cd server && npm run migrate:local && npm run dev -- --ip 127.0.0.1 --port 8787
# 2. site: yerel yapılandırmayla derle ve _headers başlıklarıyla (CSP dahil) sun
cd web && npm run build:local && npm run serve
# 3. yerel D1'e tek kullanımlık giriş jetonu yaz (geliştirme e-posta göndericisi bağlantıyı göndermez), sonra:
npm run screenshots -- http://localhost:8788 /tmp/ainotepad-web "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" <jeton>
```

`screenshots` ana sayfa, fiyat, indirme, giriş ve hesap sayfalarını 1440/390 px, açık/koyu çeker; yatay taşma, konsol
hatası ve CSP ihlali varsa çıkış kodu 1'dir. Giriş formu gerçekten gönderilir; hesap sayfası `/giris/eposta#token=…`
ile giriş yapılıp gerçek `/v1/me` verisiyle çekilir.

Yalnızca kaynak değişince elle çalıştırılanlar (çıktıları repodadır): `scripts/subset-font.sh` (yazı tipi),
`node scripts/make-grain.ts <chrome>` (film greni, `scripts/grain.svg`'den), `node scripts/make-og.ts <site> <chrome>`
(paylaşım kartı `public/og.png`, site sunulurken).

## Yapılandırma

Tek kaynak `src/config.ts`; gizli değer yoktur. Yayından önce `productionConfig` içinde "DOLDUR" ile işaretlenenler:

| Değer | Not |
|---|---|
| `siteOrigin` | Sitenin alan adı; sunucunun `SITE_ORIGIN`'i ile birebir aynı (CORS) |
| `apiBase` | Worker adresi; CSP `connect-src` bundan üretilir |
| `turnstileSiteKey` | Turnstile site anahtarı (şu an Cloudflare'in her zaman geçen deneme anahtarı); alan adı Turnstile panelinde izinli olmalı |
| `appleServiceId` | Apple Developer'daki web Services ID; sunucunun `APPLE_CLIENT_IDS` listesinde de olmalı |

DMG adresi `latestVersion`'dan üretilir: yayın betiği DMG'ye sürümlü ad verdiği için (`AI-Notepad-<sürüm>.dmg`)
`releases/latest/download/…` kalıbı bir sonraki sürümde 404 olur. Her yayında `latestVersion` güncellenir. Yayın
sabit adlı bir kopya da yüklerse (ör. `AI-Notepad.dmg`) adres `releases/latest/download/AI-Notepad.dmg` yapılabilir.

Yasal metinlerdeki işletmeci bilgileri `src/legal/operator.ts`'tedir ("[DOLDUR: …]" sayfada görünür); "[Doğrula: …]"
notları hukuki gözden geçirmede kapatılır.

Apple Services ID ayarı: alan adı `siteOrigin`'in alan adı, dönüş adresleri `<siteOrigin>/tr/giris` ve
`<siteOrigin>/en/sign-in` (giriş açılır pencereyle yapılır, Apple yine de adresi denetler).

## Cloudflare Pages

| Ayar | Değer |
|---|---|
| Kök klasör | `web` |
| Derleme komutu | `npm ci && npm run build` |
| Çıktı klasörü | `dist` |
| Ortam değişkeni | `NODE_VERSION=26` |

Derleme `../App` altındaki yazı tipi lisansını ve uygulama simgesini kopyalar; Pages tüm depoyu çektiği için ek ayar
gerekmez. `_headers` (CSP, HSTS, Referrer-Policy, Permissions-Policy, önbellek) derlemede yapılandırmadan yazılır.
Sunucunun sabit dönüş adresleri (`/hesap`, `/fiyat`, `/giris/eposta`) okuyanın dilindeki sayfaya yönlenir; sorgu ve
`#` parçası korunur.

# Gistsmith web sitesi

Cloudflare Pages'te durağan, yalnızca İngilizce site (https://gistsmith.com): tanıtım, fiyat, indirme, giriş (Apple ve
Google), hesap, iletişim formu, yönetim paneli ve yasal metinler. Abonelik sunucusuyla (`../server`,
https://api.gistsmith.com) tarayıcıdan konuşur.

**Yığın:** Astro (durağan çıktı) ve katı TypeScript. Sayfalar derlemede HTML olur; tarayıcıya yalnızca küçük betikler
gider. Satır içi betik ve stil yoktur (CSP `'unsafe-inline'` istemez). İzleyici, analiz ve CDN yazı tipi yoktur; Inter
uygulamanın dosyasından (`../App/Fonts`) küçültülüp sunulur.

## Adresler

| Yol | Sayfa |
|---|---|
| `/` | Ana sayfa |
| `/pricing` | Fiyat (Stripe Checkout iptali buraya döner) |
| `/download` | İndirme ve kurulum |
| `/sign-in` | Apple ve Google ile giriş; Apple dönüş adresi; Mac uygulaması `?app=1&nonce=<64 hex>` ile açar |
| `/account` | Hesap (`?payment=done`: Stripe Checkout dönüşü; Müşteri Portalı dönüşü `/account`) |
| `/contact` | İletişim formu |
| `/admin` | Yönetim paneli (menüde ve site haritasında yok, `noindex`) |
| `/privacy`, `/terms` | Yasal metinler |

Yollar `src/routes.ts`'tedir; `/account` ve `/admin` `Cache-Control: no-store` alır. Tüm indirme düğmeleri
`<apiBase>/v1/download/mac` adresine gider: sunucu indirmeyi günlük sayaca ekler ve DMG'ye yönlendirir (302).

## Geliştirme

```bash
cd web
npm ci
npm run dev           # http://localhost:8788, yerel yapılandırma (API: http://127.0.0.1:8787)
npm run typecheck
npm run build         # yayın yapılandırmasıyla dist/
npm run build:local && npm run serve   # yerel yapılandırmayla derle, _headers başlıklarıyla (CSP dahil) sun
npm run screenshots -- http://localhost:8788 /tmp/gistsmith-web "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# uçtan uca (giriş, uygulama adına giriş, hesap, sekme kopyası, CSP): build:local + serve, sunucu wrangler dev ile
# (--var SITE_ORIGIN:<site adresi>; ayrıntı betiğin başında)
node scripts/e2e.ts http://localhost:8788 http://127.0.0.1:8787 "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

`screenshots` tüm sayfaları 1440/390 px, açık/koyu çeker; ana sayfa gösteriminin karelerini alır, tema düğmesinin
seçimi hatırladığını ve gösterimin 5 saniyelik ana iş parçacığı maliyetini denetler. Yatay taşma, konsol hatası ya da CSP
ihlali varsa çıkış kodu 1'dir. Hesap ve yönetim sayfaları için sekmeye örnek bir oturum yazılır ve API yanıtları
betikteki örnek verilerle karşılanır (yalnızca görünüm denetimi; sunucu akışı sunucunun testlerindedir). Google Identity
Services'in sayfaya eklediği `<style>` öğeleri ve yer tutucu simgesi CSP'ye takılır (Google'ın belgelediği CSP bunlara
izin vermez; asıl düğme iframe'de çizilir ve etkilenmez); betik bunları beklenen hata sayar.

Yalnızca kaynak değişince elle çalıştırılanlar (çıktıları repodadır): `scripts/subset-font.sh` (yazı tipi),
`node scripts/make-grain.ts <chrome>` (film greni, `scripts/grain.svg`'den), `node scripts/make-og.ts <site> <chrome>`
(paylaşım kartı `public/og.png`, site sunulurken; ürün adını `productName`'den alır).

## Yapılandırma

Tek kaynak `src/config.ts`; gizli değer yoktur.

| Değer | Not |
|---|---|
| `productName` | Ürün adı; başlıklar, meta, paylaşım kartı etiketleri, metinler ve yasal metinler bundan üretilir |
| `siteOrigin` | Sitenin alan adı; sunucunun `SITE_ORIGIN`'i ile birebir aynı (CORS) |
| `apiBase` | Worker adresi; CSP `connect-src` ve indirme adresi bundan üretilir |
| `turnstileSiteKey` | İletişim formunun Turnstile site anahtarı; site alan adı Turnstile parçacığında izinli olmalı |
| `appleServiceId` | Apple Developer'daki web Services ID'si (`com.senoldogan.AINotepad.web`); sunucunun `APPLE_CLIENT_IDS` listesinde de olmalı |
| `googleClientId` | Google Cloud Console'daki web OAuth istemcisi; izinli JavaScript kaynakları: `https://gistsmith.com`, `http://localhost:8788`, `http://localhost`; sunucunun Google istemci kimliklerinde de olmalı |

İşletmeci bilgileri (ad, Y-tunnus, adres, iletişim e-postası) ve yasal metinlerin tarihi `src/legal/operator.ts`'tedir.

Ad değişince elle güncellenecekler: `public/og.png` (`make-og.ts` ile yeniden üretilir); uygulama simgesi
(`apple-touch-icon.png`, uygulamadan kopyalanır) ve `favicon.svg` yazı içermez. Tarayıcı depolama anahtarları
(`gistsmith.theme`, `gistsmith.session`) ürün adını taşır ve gizlilik politikasında adlarıyla geçer. İç kimlikler bilerek
eski adı taşır: uygulama adres şeması (`com.senoldogan.ainotepad.hosted://`) ve Apple Services ID.

**Tema.** `public/theme.js` `<head>`'de engelleyici harici betik olarak yüklenir (CSP satır içi betiğe izin vermez) ve
ilk boyamadan önce `<html data-theme>` yazar: kullanıcının seçimi (`localStorage`) yoksa sistem tercihi. Renkler
`global.css`'te `light-dark()` ile tek yerde tanımlıdır; betik yoksa `color-scheme` sistemi izler.

**Giriş.** Apple ve Google'da tarayıcı ham bir nonce üretir, sağlayıcıya SHA-256 özetini verir, kimlik jetonunu ham
nonce'la sunucuya yollar (`/v1/auth/apple`, `/v1/auth/google`); oturum sekmeye özgü `sessionStorage`'da tutulur. Mac
uygulaması `/sign-in?app=1&nonce=<özet>` ile açtığında yalnızca Google düğmesi görünür, uygulamanın özeti Google'a
olduğu gibi verilir ve jeton sunucuya değil `com.senoldogan.ainotepad.hosted://auth/google#idToken=…` ile uygulamaya
iletilir (`src/client/app-handoff.ts`). Geçerli `nonce` yoksa sayfa açık bir hata gösterir.

Apple Services ID ayarı: alan adı `gistsmith.com`, dönüş adresi `https://gistsmith.com/sign-in` (giriş açılır
pencereyle yapılır, Apple yine de adresi denetler).

**CSP.** `src/lib/headers.ts` yapılandırmadan üretir. Google Identity Services için Google'ın belgelediği kaynaklar:
`script-src https://accounts.google.com/gsi/client`, `frame-src https://accounts.google.com/gsi/`,
`connect-src https://accounts.google.com/gsi/`, `style-src https://accounts.google.com/gsi/style`. Dış hizmetler yalnızca
kullanıldıkları sayfada açıktır: Apple ve Google `/sign-in`'de, Turnstile `/contact`'ta. Pages aynı başlığı birden çok
kurala uyan adreste virgülle birleştirir ve tarayıcı iki politikayı birlikte uygular: `/*` tüm hizmetlere izin veren geniş
politikayı (sayfası olmayan adresler için), her sayfanın kuralı dar politikayı taşır. `npm run serve` başlıkları aynı
biçimde birleştirir.

## Cloudflare Pages

| Ayar | Değer |
|---|---|
| Kök klasör | `web` |
| Derleme komutu | `npm ci && npm run build` |
| Çıktı klasörü | `dist` |
| Ortam değişkeni | `NODE_VERSION=26` |

Derleme `../App` altındaki yazı tipi lisansını ve uygulama simgesini kopyalar; Pages tüm depoyu çektiği için ek ayar
gerekmez. `_headers` (CSP, HSTS, Referrer-Policy, Permissions-Policy, önbellek) derlemede yapılandırmadan yazılır.

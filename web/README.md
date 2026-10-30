# Gistsmith web sitesi

Cloudflare Pages'te durağan, yalnızca İngilizce site (https://gistsmith.com): tanıtım, fiyat, indirme, giriş (Apple ve
Google), davet, hesap, iletişim formu, yönetim paneli ve yasal metinler. Abonelik sunucusuyla (`../server`,
https://api.gistsmith.com) tarayıcıdan konuşur.

**Yığın:** Astro (durağan çıktı) ve katı TypeScript. Sayfalar derlemede HTML olur; tarayıcıya yalnızca küçük betikler
gider. Satır içi betik ve stil yoktur (CSP `'unsafe-inline'` istemez). Reklam ya da izleme betiği ve CDN yazı tipi
yoktur; Inter uygulamanın dosyasından (`../App/Fonts`) küçültülüp sunulur. Ziyaret istatistiği yalnızca Cloudflare Web
Analytics'tir: Cloudflare panelinde Pages projesi (`ainotepad`) için açılır ve işaretçi betiğini Cloudflare her sayfaya
kendisi ekler (repoda kodu yoktur). Çerez ya da tarayıcı depolaması kullanmaz, kişisel veri ya da parmak izi toplamaz;
yalnızca toplu sayfa görüntüleme, yönlendiren site, ülke ve cihaz türü sayar. Gizlilik politikasında anlatılır.

## Adresler

| Yol | Sayfa |
|---|---|
| `/` | Ana sayfa |
| `/pricing` | Fiyat (Stripe Checkout iptali buraya döner) |
| `/download` | İndirme ve kurulum |
| `/compare`, `/vs/granola`, `/vs/otter` | Karşılaştırma (rakip değerleri yalnızca kendi fiyat sayfalarından; `copy.ts` `compare`) |
| `/blog`, `/blog/<kısa ad>`, `/blog/rss.xml` | Blog: yazılar `src/content/blog/*.md` (içerik koleksiyonu, `src/content.config.ts`) |
| `/mcp` | Uygulamanın yerel MCP sunucusu: araçlar, bağlama, yapılandırma |
| `/sign-in` | Apple ve Google ile giriş; Apple dönüş adresi; Mac uygulaması `?app=1&nonce=<64 hex>` ile açar |
| `/invite` | Davet bağlantısı (`?code=`; sunucu `inviteUrl` üretir): kod `localStorage`'da (`gistsmith.invite`) saklanır, hesap sayfası abone olurken doğrulayıp ödemeye taşır |
| `/account` | Hesap (`?payment=done`: Stripe Checkout dönüşü; Müşteri Portalı dönüşü `/account`) |
| `/contact` | İletişim formu |
| `/admin` | Yönetim paneli (menüde ve site haritasında yok, `noindex`) |
| `/privacy`, `/terms` | Yasal metinler |

Yollar `src/routes.ts`'tedir; `/account` ve `/admin` `Cache-Control: no-store` alır. Tüm indirme düğmeleri
`<apiBase>/v1/download/mac?src=<yer>` adresine gider (`macDownloadUrl`; yer: `home-hero`, `home-cta`, `download-page`,
`account`): sunucu indirmeyi ağ başına günde bir kez, düğmenin yeri ve Referer alan adıyla sayar ve DMG'ye yönlendirir
(302). Yeni bir indirme düğmesi eklerken yerini sunucunun izin listesine de (`server/src/downloads.ts`) ekle.

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
betikteki örnek verilerle karşılanır (yalnızca görünüm denetimi; sunucu akışı sunucunun testlerindedir).

Yalnızca kaynak değişince elle çalıştırılanlar (çıktıları repodadır): `scripts/subset-font.sh` (yazı tipi),
`node scripts/make-grain.ts <chrome>` (film greni, `scripts/grain.svg`'den), `node scripts/make-og.ts <site> <chrome>`
(paylaşım kartı `public/og.png`, site sunulurken; ürün adını `productName`'den alır). Betiğin çıktısı ~1,1 MB'tır;
bazı önizleyiciler (ör. WhatsApp) büyük görseli atladığı için repodaki kopya 128 renkli paletli PNG'ye indirilir (300 KB
altı, ör. Pillow: `Image.open(p).convert("RGB").quantize(colors=128, method=Image.Quantize.MAXCOVERAGE).save(p, optimize=True)`).

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
(`gistsmith.theme`, `gistsmith.session`, `gistsmith.invite`, `gistsmith.plan`) ürün adını taşır ve gizlilik politikasında adlarıyla geçer. İç kimlikler bilerek
eski adı taşır: uygulama adres şeması (`com.senoldogan.ainotepad.hosted://`) ve Apple Services ID.

**Tema.** `public/theme.js` `<head>`'de engelleyici harici betik olarak yüklenir (CSP satır içi betiğe izin vermez) ve
ilk boyamadan önce `<html data-theme>` yazar: kullanıcının seçimi (`localStorage`) yoksa sistem tercihi. Renkler
`global.css`'te `light-dark()` ile tek yerde tanımlıdır; betik yoksa `color-scheme` sistemi izler.

**Giriş.** Apple ve Google'da tarayıcı ham bir nonce üretir, sağlayıcıya SHA-256 özetini verir, kimlik jetonunu ham
nonce'la sunucuya yollar (`/v1/auth/apple`, `/v1/auth/google`); oturum sekmeye özgü `sessionStorage`'da tutulur. Mac
uygulaması `/sign-in?app=1&nonce=<özet>&provider=<apple|google>` ile açtığında sayfa düğme göstermeden seçilen
sağlayıcıya yönlendirir (`provider` yoksa ya da sağlayıcıdan vazgeçilip dönülürse Apple ve Google düğmeleri birlikte
görünür; ikisi de açılır pencere yerine yönlendirme kullanır). Uygulamanın özeti sağlayıcıya olduğu gibi verilir ve jeton
sunucuya değil `com.senoldogan.ainotepad.hosted://auth/<apple|google>#idToken=…` ile uygulamaya iletilir
(`src/client/app-handoff.ts`). Geçerli `nonce` ya da bilinen bir `provider` yoksa sayfa açık bir hata gösterir.

Apple Services ID ayarı: alan adı `gistsmith.com`, dönüş adresi `https://gistsmith.com/sign-in` (sitenin kendi girişi
açılır pencereyle yapılır; Mac uygulaması adına girişte Apple kimlik jetonunu bu adrese `#` parçasıyla döndürür, adres
birebir eşleşmeli).

**CSP.** `src/lib/headers.ts` yapılandırmadan üretir. Dış hizmetler yalnızca kullanıldıkları sayfada açıktır: Apple'ın
betiği `/sign-in`'de, Turnstile `/contact`'ta (Google ile giriş Google'a yönlendirir, betik yüklenmez). Pages aynı başlığı
birden çok kurala uyan adreste virgülle birleştirir ve tarayıcı iki politikayı birlikte uygular: `/*` tüm hizmetlere izin
veren geniş politikayı (sayfası olmayan adresler için), her sayfanın kuralı dar politikayı taşır. Her sayfada çalışan
Cloudflare Web Analytics işaretçisi bu yüzden iki katmanın da tüm politikalarında açıktır:
`script-src https://static.cloudflareinsights.com`, `connect-src https://cloudflareinsights.com`. `npm run serve`
başlıkları aynı biçimde birleştirir.

## Cloudflare Pages

| Ayar | Değer |
|---|---|
| Kök klasör | `web` |
| Derleme komutu | `npm ci && npm run build` |
| Çıktı klasörü | `dist` |
| Ortam değişkeni | `NODE_VERSION=26` |

Derleme `../App` altındaki yazı tipi lisansını ve uygulama simgesini kopyalar; Pages tüm depoyu çektiği için ek ayar
gerekmez. `_headers` (CSP, HSTS, Referrer-Policy, Permissions-Policy, önbellek) derlemede yapılandırmadan yazılır.

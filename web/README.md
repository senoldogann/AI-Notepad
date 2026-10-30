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
| `/blog`, `/blog/<kısa ad>`, `/blog/rss.xml` | Blog: yazılar `src/content/blog/*.md` (içerik koleksiyonu, `src/content.config.ts`); taslaklar ve tarihi derleme gününden sonra olan yazılar yayımlanmaz (aşağıda "Haftalık blog") |
| `/blog/<kısa ad>/og.png` | Yazının paylaşım görseli (1200×630; derlemeden sonra `npm run og:blog` üretir, repoda yok) |
| `/blog/<kısa ad>/<ad>.webp` | Yazının görselleri (`public/blog/<kısa ad>/`; yönetim panelinden yüklenir) |
| `/<anahtar>.txt` | IndexNow anahtar dosyası (`config.ts` `indexNowKey`'den derlemede yazılır) |
| `/mcp` | Uygulamanın yerel MCP sunucusu: araçlar, bağlama, yapılandırma |
| `/sign-in` | Apple ve Google ile giriş; Apple dönüş adresi; Mac uygulaması `?app=1&nonce=<64 hex>` ile açar |
| `/invite` | Davet bağlantısı (`?code=`; sunucu `inviteUrl` üretir): kod `localStorage`'da (`gistsmith.invite`) saklanır, hesap sayfası abone olurken doğrulayıp ödemeye taşır |
| `/account` | Hesap (`?plan=…&checkout=1`: fiyat sayfasından seçilen plan ve ödemeye devam niyeti — giriş bitince Checkout açılır; `?payment=done`: Stripe Checkout dönüşü; Müşteri Portalı dönüşü `/account`) |
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
npm run og:blog -- "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"   # derlemeden sonra: yazıların paylaşım görselleri
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
(paylaşım kartı `public/og.png`, site sunulurken; ürün adını `productName`'den alır).

**Paylaşım görselleri.** Chrome'un 1200×630 ekran görüntüsü gren yüzünden ~1,1 MB'tır; bazı önizleyiciler (ör. WhatsApp)
300 KB'tan büyük görseli atladığı için `scripts/og-image.ts` görüntüyü bütçeye sığan en çok renkli paletli PNG'ye indirir
(sharp/libimagequant; 128 renkten 32'ye; en küçüğü de sığmazsa hata). Blog yazılarının görselleri derlemede değil,
derlemeden sonra üretilir (`npm run og:blog -- <chrome>`, `scripts/make-blog-og.ts`): site haritasındaki her yazının
sayfası Chrome'da dist/'ten açılır, sayfanın kapağı (`BlogCover.astro`, `[data-og-cover]`) 1200 px genişlikte yalnız
bırakılır, logo, ürün adı ve alan adı eklenir. Kapak sitenin kendi CSS'iyle çizildiği için görsel sayfadakiyle aynıdır;
satori + resvg gibi saf çiziciler kapağın katmanlı radyal gradyanlarını, `color-mix`'ini, gren ve kenar kararması
karışımlarını (`mix-blend-mode`) çizemediği için Chrome seçildi (GitHub'ın ubuntu-latest runner'ında
`/usr/bin/google-chrome` kurulu gelir). Görseli olmayan yazı sayfası bozuk `og:image` verir: yayından önce bu adım
çalışmalı (iş akışı ve elle yayın komutu çalıştırır).

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
`script-src https://static.cloudflareinsights.com`, `connect-src https://cloudflareinsights.com`. Yönetim panelinde
`img-src` ayrıca `blob:`'a izin verir: blog düzenleyicisi yüklenecek görseli ve bu oturumda yüklenenleri (site yeniden
derlenene dek) tarayıcıdaki kopyasından gösterir. `npm run serve` başlıkları aynı biçimde birleştirir.

## Yayın (Cloudflare Pages, doğrudan yükleme)

Pages projesi `ainotepad` doğrudan yüklemeyle beslenir (Git bağlantısı yok). Yayını `.github/workflows/deploy-web.yml`
yapar:

- `main`'e `web/` (ya da iş akışının kendisi) değişince; yönetim panelinden kaydedilen blog yazıları da `main`'e
  commit'tir;
- her gün 06:00 UTC'de (zamanlanmış blog yazıları tarihlerinde yayımlansın);
- elle: GitHub → Actions → "Deploy web" → Run workflow.

İş `npm ci && npm run build` (üretim yapılandırması), `npm run og:blog -- /usr/bin/google-chrome` (yazıların paylaşım
görselleri; yukarıda "Paylaşım görselleri") sonra
`npx wrangler pages deploy dist --project-name ainotepad --branch main` çalıştırır; yükleme başarılıysa son adım
`npm run indexnow`'dur (aşağıda "IndexNow"). Yayınlar üst üste binmez (`concurrency`). Depo gizli değerleri (GitHub → Settings → Secrets and variables → Actions): `CLOUDFLARE_API_TOKEN`
(Cloudflare → My Profile → API Tokens → yalnızca "Account › Cloudflare Pages › Edit" yetkili jeton) ve
`CLOUDFLARE_ACCOUNT_ID`. GitHub, 60 gün değişiklik görmeyen herkese açık depoda zamanlanmış iş akışlarını kapatır;
kapanırsa Actions sekmesinden yeniden açılır.

Elle yayın aynı komutlardır (`npx wrangler login` sonrası):

```bash
cd web && npm ci && npm run build \
  && npm run og:blog -- "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  && npx wrangler pages deploy dist --project-name ainotepad --branch main \
  && npm run indexnow
```

**IndexNow.** Yükleme başarılı olunca `scripts/indexnow.ts` yeni ve değişen blog yazılarını
`https://api.indexnow.org/indexnow`'a bildirir (Bing, Yandex, Seznam, Naver… paylaşır; Google IndexNow kullanmaz, site
haritasını ve `<lastmod>`'u okur). Adresler derlemenin site haritasından seçilir: `<lastmod>`'u (yazının `updated` ya
da `published` günü) bugün ya da dün (UTC) olan yazılar, varsa blog dizini ve site haritası da. Durum tutulmaz:
zamanlanmış yazı tarihindeki 06:00 derlemesinde, yeni ya da `updated`'ı ilerletilmiş yazı o gün ve ertesi günün
yayınlarında bildirilir (aynı adresin yeniden bildirilmesi zararsızdır); `updated` değişmeden yapılan düzeltme ve silinen
yazı bildirilmez. Değişen yazı yoksa istek gönderilmez. 429, 5xx, ağ hatası ve zaman aşımı uyarıyla (`indexnow_retry`)
3 kez denenir; denemeler biterse ya da kalıcı ret (400, 403 anahtar geçersiz, 422…) olursa durum, gövde ve adreslerle
çıkış kodu 1 (yayın zaten bitmiştir, iş kırmızı görünür). Anahtar açıktır ve depodadır (`src/config.ts` `indexNowKey`);
derleme `/<anahtar>.txt` dosyasını bu değerden yazar, betik dosyanın varlığını ve içeriğini denetler. Anahtarı
değiştirmek için yeni 32 onaltılık karakter yazmak yeter (eski dosya bir sonraki yayında kalkar).

Derleme `../App` altındaki yazı tipi lisansını ve uygulama simgesini kopyalar (depo bütün olarak çekilir).
`_headers` (CSP, HSTS, Referrer-Policy, Permissions-Policy, önbellek) derlemede yapılandırmadan yazılır.

## Haftalık blog

Her yazı `src/content/blog/<kısa ad>.md`'dir; ön bilgi alanları `title` (10–90), `description` (50–170), `author`,
`published` (`YYYY-MM-DD`) ve `draft`'tır (her yazıda açıkça); isteğe bağlı olanlar `updated` (`YYYY-MM-DD`,
`published`'dan önce olamaz) ve `cover`'dır (`sunset`, `coral`, `ocean`, `mint`, `rose`, `violet`). Derleme taslakları ve
`published` günü derleme gününden (UTC) sonra olan yazıları dizinden, yazı sayfalarından, RSS'ten ve site haritasından
çıkarır (`src/lib/blog.ts` → `isBlogPostPublic`; tüm sayfalar `blogEntries`'i kullanır).

- **Kapak:** her yazının kapağı durgun pastel film gradyanı, başlık ve kısa addan sabit ses dalgasıdır
  (`BlogCover.astro`). Aile ve yerleşim kısa addan seçilir (`src/lib/film.ts` `coverFilm`; aynı kısa ad her derlemede ve
  panelde aynı kapağı verir); `cover` yalnızca aileyi değiştirir. Kapak yazı sayfasının başıdır (başlık `h1`), dizinde ve
  yazı sonundaki "More from the blog"da kart görselidir; paylaşım görseli aynı kapaktan üretilir.
- **Görseller:** panelden yüklenen WebP'ler `public/blog/<kısa ad>/<ad>.webp`'dir. Markdown derlenirken her görsele
  dosyadan okunan `width`/`height`, `loading="lazy"` ve `decoding="async"` yazılır (`src/lib/blog-images.ts`; yer kayması
  olmaz). Görsel yalnızca yazının kendi klasöründen olabilir; dış adres ya da eksik dosya derlemeyi hatayla durdurur.
  Yazı silinince klasörü de aynı commit'te silinir.
- **Arama motorları:** yazı sayfası `og:type article`, `article:published_time`/`article:modified_time`, kendi
  `og:image`/`twitter:image`'ı (`summary_large_image`), `BlogPosting` (`image`, `dateModified` = `updated` ya da
  `published`) ve `BreadcrumbList` JSON-LD taşır; sonunda en çok 3 ilgili yazı vardır (kısa adlarında ortak sözcüğü çok
  olan, sonra yeni olan; `relatedPosts`). Site haritası yazılara ve blog dizinine `<lastmod>` yazar; RSS her öğeye
  paylaşım görselini `media:content` ile ekler.

Akış:

1. **Yaz:** yönetim paneli → Blog → New post (ya da dosyayı elle ekle). Düzenleyici başlıktan kısa ad türetir, açıklama
   için karakter sayar, Markdown'ı güvenli önizler; önerilen tarih bugün ile son yayında ya da zamanlanmış yazının 7 gün
   sonrasının büyüğüdür, yazar son yazınınkidir. Cover: "Auto" ya da bir aile (küçük önizlemeyle); Last updated isteğe
   bağlıdır. **Add image** (yazı bir kez kaydedildikten sonra): PNG, JPEG ya da WebP seçilir, tarayıcı en çok 1600 px
   genişliğe küçültüp WebP'ye çevirir (600 KB'ı aşarsa yüklemez), alternatif metin zorunludur, dosya adı ondan türer;
   görsel hemen `main`'e commit'lenir (`blog: image <kısa ad>/<ad>`) ve `![alt](/blog/<kısa ad>/<ad>.webp)` imlecin yerine
   eklenir (yazı ayrıca kaydedilir). Blog görünümünde "Open blog" dizini, yayındaki yazının satırındaki ve
   düzenleyicisindeki simge yazıyı yeni sekmede açar.
2. **Zamanla:** gelecek tarihli kaydet (ya da taslak bırak). Kayıt sunucu üzerinden `main`'e bir commit'tir
   (`blog: <başlık>`; bkz. `server/README.md` "Blog yayını"). Liste, son yazının tarihini ve önümüzdeki 7 günde
   zamanlanmış yazı yoksa uyarıyı gösterir.
3. **Yayımla:** commit yayını tetikler (taslak ve gelecek tarihli yazı görünmez); zamanlanmış yazı tarihindeki 06:00 UTC
   derlemesinde yayımlanır.
4. **Paylaş:** yayında olan yazının düzenleyicisinde X, LinkedIn ve Bluesky paylaşım düğmeleri hazır metinle yeni
   sekmede açılır (yazının adresi `siteOrigin` + `/blog/<kısa ad>`).

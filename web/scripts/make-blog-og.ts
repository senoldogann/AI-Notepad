// Yayımlanan her blog yazısının paylaşım görselini (1200×630 PNG, `dist/blog/<kısa ad>/og.png`) derlenmiş siteden
// üretir. Derlemeden (`npm run build`) sonra, yüklemeden önce çalışır (.github/workflows/deploy-web.yml; yerelde
// `npm run og:blog -- <Chrome yolu>`).
//
// Yazılar derlemenin kendi çıktısından seçilir: site haritasındaki `/blog/<kısa ad>` adresleri (taslak ve tarihi
// gelmemiş yazılar orada yoktur). Her yazı sayfası Chrome'da açılır (dosyalar dist/'ten, ağ yok), sayfanın kapağı
// (`[data-og-cover]`, src/components/BlogCover.astro) 1200 px genişlikte yalnız bırakılır, üstüne logo ve ürün adı, altına
// alan adı eklenir ve görüntüsü alınır. Kapak sitedeki CSS'le çizildiği için görsel sayfadakiyle birebir aynıdır (radyal
// gradyanlar, `color-mix`, gren ve kenar kararması; saf SVG çiziciler bunları çizemez). Hedef yol sayfanın kendi
// `og:image` adresinden okunur; beklenen `/blog/<kısa ad>/og.png` değilse ya da kapak bulunamazsa açık hata verilir.
// Kullanım: node scripts/make-blog-og.ts <Chrome yolu>
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { type Browser, type BrowserContext, type Page, type Route, chromium } from "playwright-core";
import { productName } from "../src/config.ts";
import { blogOgImagePath } from "../src/routes.ts";
import { type Resolved, contentTypes, resolveDistFile } from "./dist.ts";
import { logoSvg, ogViewport, writeOgPng } from "./og-image.ts";

/** Görsel üretilemedi: eksik kapak, beklenmeyen `og:image` ya da yüklenemeyen dosya. */
class BlogOgError extends Error {
  override readonly name: string = "BlogOgError";
}

/** Sayfaların açıldığı sahte kaynak: istekler dist/'ten karşılanır, dışarı istek çıkmaz. */
const localOrigin: string = "http://og.invalid";
const distDir: string = fileURLToPath(new URL("../dist/", import.meta.url));

/** Komut satırı bağımsız değişkeni; yoksa hata. */
function argument(index: number, name: string): string {
  const value: string | undefined = process.argv[index];
  if (value === undefined || value === "") {
    throw new BlogOgError(`Eksik bağımsız değişken: ${name}. Kullanım: node scripts/make-blog-og.ts <chrome>`);
  }
  return value;
}

/** Site haritasındaki blog yazılarının kısa adları (`/blog/<kısa ad>`; dizin ve RSS hariç). Saf fonksiyondur. */
function sitemapBlogSlugs(sitemap: string): string[] {
  return [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)]
    .map((match: RegExpMatchArray): string => new URL(match[1] ?? "").pathname)
    .map((path: string): RegExpExecArray | null => /^\/blog\/([a-z0-9]+(?:-[a-z0-9]+)*)$/.exec(path))
    .filter((match: RegExpExecArray | null): match is RegExpExecArray => match !== null)
    .map((match: RegExpExecArray): string => match[1] ?? "");
}

/** Görselin üstündeki ve altındaki eklerin stili (kapağın kendi stili sitenin CSS'inden gelir). */
const css: string = `
  html, body { margin: 0; background: #fdfcfc; }
  .og-frame { width: ${ogViewport.width}px; height: ${ogViewport.height}px; overflow: hidden; }
  .og-frame .blog-cover { width: ${ogViewport.width}px; }
  .og-frame .blog-cover .blog-cover__film.film { border-radius: 0; }
  .og-brand { display: flex; align-items: center; gap: 14px; color: #0a0a0a; font-size: 28px; font-weight: 600; letter-spacing: -0.02em; }
  .og-domain { position: absolute; right: 84px; bottom: 66px; z-index: 1; color: rgb(10 10 10 / 0.62); font-size: 22px; font-weight: 500; letter-spacing: -0.01em; }
`;

/** Bir yazının görselini üretir; yazılan dosyanın bayt boyunu döndürür. */
async function renderPost(page: Page, slug: string): Promise<number> {
  const response = await page.goto(`${localOrigin}/blog/${slug}`, { waitUntil: "load" });
  if (response === null || response.status() !== 200) {
    throw new BlogOgError(`Yazı sayfası açılamadı: /blog/${slug} (durum ${String(response?.status() ?? "yok")}).`);
  }
  const ogImage: string | null = await page.getAttribute('meta[property="og:image"]', "content");
  const target: string = ogImage === null ? "" : new URL(ogImage).pathname;
  if (target !== blogOgImagePath(slug)) {
    throw new BlogOgError(`/blog/${slug} sayfasının og:image adresi beklenen ${blogOgImagePath(slug)} değil: ${JSON.stringify(ogImage)}.`);
  }
  await page.addStyleTag({ content: css });
  const found: boolean = await page.evaluate(
    ({ slug: wanted, mark, name, domain }: { readonly slug: string; readonly mark: string; readonly name: string; readonly domain: string }): boolean => {
      const cover: Element | null = document.querySelector(`[data-og-cover="${wanted}"]`);
      if (cover === null) {
        return false;
      }
      const clone: Element = cover.cloneNode(true) as Element;
      const brand: HTMLDivElement = document.createElement("div");
      brand.className = "og-brand";
      brand.innerHTML = mark;
      brand.append(name);
      clone.querySelector(".blog-cover__body")?.prepend(brand);
      const site: HTMLSpanElement = document.createElement("span");
      site.className = "og-domain";
      site.textContent = domain;
      clone.querySelector(".blog-cover__film")?.append(site);
      const frame: HTMLDivElement = document.createElement("div");
      frame.className = "og-frame";
      frame.append(clone);
      document.body.replaceChildren(frame);
      return true;
    },
    { slug, mark: logoSvg(44), name: productName, domain: `${new URL(ogImage ?? "").host}/blog` },
  );
  if (!found) {
    throw new BlogOgError(`/blog/${slug} sayfasında kapak ([data-og-cover="${slug}"]) yok.`);
  }
  await page.evaluate(async (): Promise<void> => {
    await document.fonts.ready;
  });
  return writeOgPng(await page.screenshot({ clip: { x: 0, y: 0, ...ogViewport } }), join(distDir, target));
}

/** Tüm yayımlanan yazıların görsellerini üretir. */
async function main(): Promise<void> {
  const chromePath: string = argument(2, "Chrome yolu");
  const slugs: string[] = sitemapBlogSlugs(await readFile(join(distDir, "sitemap.xml"), "utf8"));
  const browser: Browser = await chromium.launch({ executablePath: chromePath, headless: true });
  try {
    const context: BrowserContext = await browser.newContext({ viewport: ogViewport, colorScheme: "light", reducedMotion: "reduce" });
    await context.route("**/*", async (route: Route): Promise<void> => {
      const url: URL = new URL(route.request().url());
      if (url.origin !== localOrigin) {
        await route.abort("blockedbyclient");
        return;
      }
      const resolved: Resolved = await resolveDistFile(distDir, url.pathname);
      const extension: string = resolved.file.slice(resolved.file.lastIndexOf("."));
      await route.fulfill({ status: resolved.status, path: resolved.file, contentType: contentTypes[extension] ?? "application/octet-stream" });
    });
    const page: Page = await context.newPage();
    const failures: string[] = [];
    page.on("requestfailed", (request): void => {
      if (new URL(request.url()).origin === localOrigin) {
        failures.push(request.url());
      }
    });
    for (const slug of slugs) {
      const bytes: number = await renderPost(page, slug);
      console.log("blog_og_written", { slug, bytes });
    }
    if (failures.length > 0) {
      throw new BlogOgError(`Sayfa dosyaları yüklenemedi: ${failures.slice(0, 5).join(", ")}`);
    }
    console.log("blog_og_done", { posts: slugs.length });
  } finally {
    await browser.close();
  }
}

await main();

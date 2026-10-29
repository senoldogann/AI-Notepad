// Paylaşım kartı görüntüsünü (public/og.png, 1200×630) üretir: sitenin film gradyanı (global.css), uygulamanın kapak
// ses dalgası (src/lib/film.ts), logo ve slogan. Derlenmiş site sunulurken (scripts/serve.ts) çalıştırılır; çıktı
// repoya girer, derleme bunu çalıştırmaz.
// Kullanım: node scripts/make-og.ts <site adresi> <Chrome yolu>
import { fileURLToPath } from "node:url";
import { type Browser, type BrowserContext, type Page, chromium } from "playwright-core";
import { productName } from "../src/config.ts";
import { type WaveBar, coverWaveHeights, waveBars } from "../src/lib/film.ts";

/** Komut satırı bağımsız değişkeni; yoksa hata. */
function argument(index: number, name: string): string {
  const value: string | undefined = process.argv[index];
  if (value === undefined || value === "") {
    throw new Error(`Eksik bağımsız değişken: ${name}. Kullanım: node scripts/make-og.ts <site> <chrome>`);
  }
  return value;
}

/** Ses dalgası SVG'si. Saf fonksiyondur. */
function waveSvg(width: number, height: number): string {
  const bars: WaveBar[] = waveBars(coverWaveHeights(productName, 23), width, height, width / 37);
  const rects: string = bars
    .map((bar: WaveBar): string => `<rect x="${bar.x.toFixed(2)}" y="${bar.y.toFixed(2)}" width="${bar.width.toFixed(2)}" height="${bar.height.toFixed(2)}" rx="${(bar.width / 2).toFixed(2)}" fill="currentColor"/>`)
    .join("");
  return `<svg class="wave" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${rects}</svg>`;
}

const logo: string = `<svg width="88" height="88" viewBox="0 0 32 32"><rect x="0.5" y="0.5" width="31" height="31" rx="8.5" fill="#0a0a0a"/><g fill="#fafafa"><rect x="7.4" y="12" width="2.6" height="8" rx="1.3"/><rect x="11.4" y="8.2" width="2.6" height="15.6" rx="1.3"/><rect x="15.4" y="10.6" width="2.6" height="10.8" rx="1.3"/><rect x="19.6" y="14.7" width="5.6" height="2.6" rx="1.3"/></g></svg>`;

const css: string = `
  html, body { margin: 0; background: #fdfcfc; }
  .og { width: 1200px; height: 630px; border-radius: 0; display: grid; place-items: center; }
  .og__content { display: grid; justify-items: center; gap: 26px; text-align: center; }
  .og__name { font-size: 30px; font-weight: 600; letter-spacing: -0.02em; color: #0a0a0a; }
  .og__title { font-size: 76px; line-height: 1.02; letter-spacing: -0.045em; font-weight: 600; color: #0a0a0a; max-width: 15ch; }
  .og__brand { display: flex; align-items: center; gap: 18px; }
`;

/** Kartı çizer ve kaydeder. */
async function main(): Promise<void> {
  const base: string = argument(2, "site adresi").replace(/\/$/, "");
  const chromePath: string = argument(3, "Chrome yolu");
  const output: string = fileURLToPath(new URL("../public/og.png", import.meta.url));
  const browser: Browser = await chromium.launch({ executablePath: chromePath, headless: true });
  try {
    // Sitenin stil dosyaları ve yazı tipi için site sayfası açılır; içerik betikle değiştirildiğinden CSP atlanır.
    const context: BrowserContext = await browser.newContext({ viewport: { width: 1200, height: 630 }, colorScheme: "light", bypassCSP: true });
    const page: Page = await context.newPage();
    await page.goto(`${base}/404`, { waitUntil: "load" });
    await page.addStyleTag({ content: css });
    await page.evaluate(
      ({ wave, mark, name }: { readonly wave: string; readonly mark: string; readonly name: string }): void => {
        document.body.innerHTML = `<div class="film film--sunset film--clouds-left og"><div class="og__content">
          <div class="og__brand">${mark}<span class="og__name">${name}</span></div>
          <p class="og__title">Listens to your meetings, writes your notes.</p>${wave}</div></div>`;
      },
      { wave: waveSvg(260, 56), mark: logo, name: productName },
    );
    await page.evaluate(async (): Promise<void> => {
      await document.fonts.ready;
    });
    await page.screenshot({ path: output, clip: { x: 0, y: 0, width: 1200, height: 630 } });
    console.log("og_written", { output });
  } finally {
    await browser.close();
  }
}

await main();

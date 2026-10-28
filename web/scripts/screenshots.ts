// Uçtan uca görsel deneme: derlenmiş site (scripts/serve.ts) ve yerel abonelik sunucusu (server/, `npm run dev`)
// çalışırken sayfaların 1440 ve 390 px, açık ve koyu ekran görüntülerini alır; yatay taşmayı, konsol hatalarını ve CSP
// ihlallerini raporlar. Giriş formu gerçek Turnstile deneme anahtarıyla gönderilir; hesap sayfası verilen tek
// kullanımlık e-posta jetonuyla (yerel D1'e yazılmış) giriş yapılarak gerçek `/v1/me` verisiyle çekilir.
// Kullanım: node scripts/screenshots.ts <site adresi> <çıktı klasörü> <Chrome yolu> <giriş jetonu>
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { type Browser, type BrowserContext, type ConsoleMessage, type Page, chromium } from "playwright-core";

/** Ekran boyutu ve renk teması. */
interface Variant {
  readonly name: string;
  readonly width: number;
  readonly colorScheme: "light" | "dark";
}

/** Bir sayfadaki sorunlar. */
interface Finding {
  readonly shot: string;
  readonly problem: string;
}

const variants: readonly Variant[] = [
  { name: "1440-light", width: 1440, colorScheme: "light" },
  { name: "1440-dark", width: 1440, colorScheme: "dark" },
  { name: "390-light", width: 390, colorScheme: "light" },
  { name: "390-dark", width: 390, colorScheme: "dark" },
];

/** Görüntülenecek sayfalar; `ready` sayfanın hazır olduğunu gösteren seçici (Turnstile ağı hiç boşaltmaz). */
const pages: readonly { readonly name: string; readonly path: string; readonly ready: string }[] = [
  { name: "home", path: "/tr", ready: "main" },
  { name: "home-en", path: "/en", ready: "main" },
  { name: "pricing", path: "/tr/fiyat", ready: "main" },
  { name: "download", path: "/tr/indir", ready: "main" },
  { name: "signin", path: "/tr/giris", ready: "#email-submit:not([disabled])" },
];

/** Komut satırı bağımsız değişkeni; yoksa hata. */
function argument(index: number, name: string): string {
  const value: string | undefined = process.argv[index];
  if (value === undefined || value === "") {
    throw new Error(`Eksik bağımsız değişken: ${name}. Kullanım: node scripts/screenshots.ts <site> <çıktı> <chrome> <jeton>`);
  }
  return value;
}

/** Sayfanın konsol hatalarını ve yakalanmamış hatalarını toplar. */
function collectErrors(page: Page, shot: () => string, findings: Finding[]): void {
  page.on("console", (message: ConsoleMessage): void => {
    if (message.type() === "error") {
      findings.push({ shot: shot(), problem: `console: ${message.text()}` });
    }
  });
  page.on("pageerror", (error: Error): void => {
    findings.push({ shot: shot(), problem: `pageerror: ${error.message}` });
  });
}

/** Yatay taşmayı denetler: belge genişliği ve ekran dışına taşan öğeler. */
async function checkOverflow(page: Page, shot: string, findings: Finding[]): Promise<void> {
  const overflow: { readonly scrollWidth: number; readonly viewport: number; readonly offenders: string[] } = await page.evaluate(() => {
    const viewport: number = document.documentElement.clientWidth;
    const offenders: string[] = [];
    for (const element of Array.from(document.querySelectorAll("body *"))) {
      const rect: DOMRect = element.getBoundingClientRect();
      if (rect.width > 0 && (rect.right > viewport + 1 || rect.left < -1) && getComputedStyle(element).position !== "fixed") {
        const insideClip: boolean = element.closest(".film, .faq, dialog, .visually-hidden, .skip-link") !== null;
        if (!insideClip) {
          offenders.push(`${element.tagName.toLowerCase()}.${String(element.className).split(" ").join(".")} (${Math.round(rect.left)}–${Math.round(rect.right)})`);
        }
      }
    }
    return { scrollWidth: document.documentElement.scrollWidth, viewport, offenders: offenders.slice(0, 5) };
  });
  if (overflow.scrollWidth > overflow.viewport) {
    findings.push({ shot, problem: `yatay kaydırma: ${overflow.scrollWidth} > ${overflow.viewport}` });
  }
  for (const offender of overflow.offenders) {
    findings.push({ shot, problem: `ekran dışına taşan öğe: ${offender}` });
  }
}

/** Sayfayı açar, yazı tipinin yüklenmesini bekler, taşmayı denetler ve tam sayfa görüntüsünü kaydeder. */
async function capture(page: Page, outDir: string, shot: string, findings: Finding[]): Promise<void> {
  await page.evaluate(async (): Promise<void> => {
    await document.fonts.ready;
  });
  await checkOverflow(page, shot, findings);
  await page.screenshot({ path: join(outDir, `${shot}.png`), fullPage: true });
}

/** Yeni bağlam: Türkçe tarayıcı, hareket azaltılmış (kaydırmaya bağlı belirme tam sayfa görüntüde içeriği gizlemesin). */
async function newContext(browser: Browser, variant: Variant): Promise<BrowserContext> {
  return browser.newContext({
    viewport: { width: variant.width, height: 900 },
    deviceScaleFactor: variant.width < 600 ? 2 : 1,
    colorScheme: variant.colorScheme,
    reducedMotion: "reduce",
    locale: "tr-TR",
  });
}

/** Durgun sayfaların görüntüleri. */
async function captureStaticPages(browser: Browser, base: string, outDir: string, findings: Finding[]): Promise<void> {
  for (const variant of variants) {
    const context: BrowserContext = await newContext(browser, variant);
    for (const target of pages) {
      const shot: string = `${target.name}-${variant.name}`;
      const page: Page = await context.newPage();
      collectErrors(page, (): string => shot, findings);
      await page.goto(`${base}${target.path}`, { waitUntil: "load" });
      await page.waitForSelector(target.ready, { timeout: 20_000 });
      await capture(page, outDir, shot, findings);
      await page.close();
    }
    await context.close();
  }
}

/** Giriş formu: Turnstile deneme anahtarı geçer, form gerçek sunucuya gönderilir, "e-postanı kontrol et" görünür. */
async function captureEmailSent(browser: Browser, base: string, outDir: string, findings: Finding[]): Promise<void> {
  const variant: Variant = { name: "1440-light", width: 1440, colorScheme: "light" };
  const context: BrowserContext = await newContext(browser, variant);
  const page: Page = await context.newPage();
  const shot: string = "signin-sent-1440-light";
  collectErrors(page, (): string => shot, findings);
  await page.goto(`${base}/tr/giris`, { waitUntil: "load" });
  await page.fill("#email", "deneme@example.com");
  await page.waitForSelector("#email-submit:not([disabled])", { timeout: 20_000 });
  await page.click("#email-submit");
  await page.waitForSelector("#signin-sent:not(.hidden)", { timeout: 20_000 });
  await capture(page, outDir, shot, findings);
  await context.close();
}

/** Hesap sayfası: e-posta bağlantısıyla (dile özgü olmayan `/giris/eposta`) giriş, sonra her görünümde yeniden yükleme. */
async function captureAccount(browser: Browser, base: string, outDir: string, token: string, findings: Finding[]): Promise<void> {
  const context: BrowserContext = await newContext(browser, { name: "1440-light", width: 1440, colorScheme: "light" });
  const page: Page = await context.newPage();
  let shot: string = "account-login";
  collectErrors(page, (): string => shot, findings);
  await page.goto(`${base}/giris/eposta#token=${token}`);
  await page.waitForURL(`${base}/tr/hesap`, { timeout: 20_000 });
  for (const variant of variants) {
    shot = `account-${variant.name}`;
    await page.setViewportSize({ width: variant.width, height: 900 });
    await page.emulateMedia({ colorScheme: variant.colorScheme, reducedMotion: "reduce" });
    await page.reload({ waitUntil: "load" });
    await page.waitForSelector("#account-content:not(.hidden)", { timeout: 20_000 });
    await capture(page, outDir, shot, findings);
  }
  shot = "account-delete-dialog";
  await page.click("#delete-button");
  await page.fill("#confirm-input", "sil");
  await page.waitForSelector("#confirm-delete:not([disabled])");
  await page.screenshot({ path: join(outDir, `${shot}-390-dark.png`) });
  await context.close();
}

/** Tüm görüntüleri alır ve sorunları yazdırır; sorun varsa çıkış kodu 1. */
async function main(): Promise<void> {
  const base: string = argument(2, "site adresi").replace(/\/$/, "");
  const outDir: string = argument(3, "çıktı klasörü");
  const chromePath: string = argument(4, "Chrome yolu");
  const token: string = argument(5, "giriş jetonu");
  await mkdir(outDir, { recursive: true });
  const browser: Browser = await chromium.launch({ executablePath: chromePath, headless: true });
  const findings: Finding[] = [];
  try {
    await captureStaticPages(browser, base, outDir, findings);
    await captureEmailSent(browser, base, outDir, findings);
    await captureAccount(browser, base, outDir, token, findings);
  } finally {
    await browser.close();
  }
  for (const finding of findings) {
    console.log("finding", finding);
  }
  console.log("screenshots_done", { outDir, findings: findings.length });
  process.exitCode = findings.length === 0 ? 0 : 1;
}

await main();

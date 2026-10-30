// Yayından sonra yeni ve değişen blog yazılarını IndexNow'a bildirir (https://api.indexnow.org/indexnow; Bing, Yandex,
// Seznam, Naver… bildirimi paylaşır). .github/workflows/deploy-web.yml Cloudflare Pages yüklemesi başarılı olunca
// çalıştırır; yerelde `npm run indexnow` (yalnızca üretim derlemesiyle; gerçek bildirim gönderir).
//
// Hangi adresler: derlemenin site haritasındaki (dist/sitemap.xml) blog yazılarından `<lastmod>`'u (yazının `updated`
// ya da `published` günü) bugün ya da dün (UTC) olanlar; varsa bunlara blog dizini ve site haritası eklenir. Durum
// tutulmaz: zamanlanmış yazı tarihindeki 06:00 UTC derlemesinde, yeni ya da `updated`'ı ilerletilmiş yazı kaydedildiği
// günün (ve ertesi günün) yayınlarında bildirilir; aynı adresin aynı gün yeniden bildirilmesi zararsızdır. `updated`
// değişmeden yapılan düzeltme bildirilmez. Değişen yazı yoksa hiçbir şey gönderilmez.
//
// Anahtar config.ts `indexNowKey`'dir; derleme onu `/<anahtar>.txt` olarak yazar (dosya yoksa ya da içeriği farklıysa
// hata). İstek 429, 5xx, ağ hatası ve zaman aşımında uyarıyla 3 kez denenir; 200 ve 202 başarıdır. Denemeler bitince
// ya da kalıcı ret (400, 403, 422…) olursa durum, yanıt gövdesi ve adreslerle hata verir (çıkış kodu 1). Yayın bundan
// önce bittiği için bildirim hatası yayını geri almaz; iş akışı kırmızı görünür.
// Kullanım: node scripts/indexnow.ts
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { indexNowKey } from "../src/config.ts";

/** Bildirim gönderilemedi ya da derleme bildirime uygun değil. */
class IndexNowError extends Error {
  override readonly name: string = "IndexNowError";
}

/** Site haritasındaki adres ve son değişiklik günü (yoksa null). */
interface SitemapUrl {
  readonly loc: string;
  readonly lastmod: string | null;
}

/** IndexNow isteğinin gövdesi. */
interface IndexNowBody {
  readonly host: string;
  readonly key: string;
  readonly keyLocation: string;
  readonly urlList: readonly string[];
}

const endpoint: string = "https://api.indexnow.org/indexnow";
const attempts: number = 3;
const timeoutMs: number = 20_000;
const retryBaseDelayMs: number = 2_000;
const dayMs: number = 86_400_000;
const distDir: string = fileURLToPath(new URL("../dist/", import.meta.url));

/** Site haritasının adresleri. Saf fonksiyondur. */
function sitemapUrls(xml: string): SitemapUrl[] {
  return [...xml.matchAll(/<url>([\s\S]*?)<\/url>/g)].map((match: RegExpMatchArray): SitemapUrl => {
    const block: string = match[1] ?? "";
    const loc: string | undefined = /<loc>([^<]+)<\/loc>/.exec(block)?.[1];
    if (loc === undefined) {
      throw new IndexNowError(`Site haritasında <loc>'suz <url> var: ${block.trim().slice(0, 120)}`);
    }
    return { loc, lastmod: /<lastmod>([^<]+)<\/lastmod>/.exec(block)?.[1] ?? null };
  });
}

/**
 * Bildirilecek adresler: `<lastmod>`'u `since` gününe (YYYY-AA-GG) eşit ya da sonra olan blog yazıları; varsa blog
 * dizini ve site haritası da. Değişen yazı yoksa boş. Saf fonksiyondur.
 */
function changedUrls(urls: readonly SitemapUrl[], origin: string, since: string): string[] {
  const posts: string[] = urls
    .filter((url: SitemapUrl): boolean => /^\/blog\/[a-z0-9]+(?:-[a-z0-9]+)*$/.test(new URL(url.loc).pathname) && url.lastmod !== null && url.lastmod >= since)
    .map((url: SitemapUrl): string => url.loc);
  return posts.length === 0 ? [] : [...posts, `${origin}/blog`, `${origin}/sitemap.xml`];
}

/** Yeniden denenebilir durum: 429 ve 5xx. Saf fonksiyondur. */
function isRetryableStatus(status: number): boolean {
  return status === 429 || status >= 500;
}

/** Bekler. */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

/** Tek deneme: 200/202'de durum; yeniden denenebilir hatada `retry`, kalıcı hatada `IndexNowError`. */
async function submitOnce(body: IndexNowBody): Promise<{ readonly status: number; readonly retry: boolean; readonly detail: string }> {
  let response: Response;
  try {
    response = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json; charset=utf-8" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error: unknown) {
    const retryable: boolean = error instanceof TypeError || (error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError"));
    if (!retryable) {
      throw error;
    }
    return { status: 0, retry: true, detail: `${error instanceof Error ? error.name : "Error"}: ${error instanceof Error ? error.message : String(error)}` };
  }
  const text: string = (await response.text()).slice(0, 500);
  if (response.status === 200 || response.status === 202) {
    return { status: response.status, retry: false, detail: text };
  }
  if (isRetryableStatus(response.status)) {
    return { status: response.status, retry: true, detail: text };
  }
  throw new IndexNowError(`IndexNow isteği reddetti (durum ${response.status}): ${text} — host ${body.host}, adresler ${body.urlList.join(", ")}`);
}

/** Bildirimi gönderir; geçici hatada uyarıyla yeniden dener, denemeler bitince son hatayı fırlatır. */
async function submit(body: IndexNowBody): Promise<number> {
  for (let attempt: number = 1; attempt <= attempts; attempt += 1) {
    const result = await submitOnce(body);
    if (!result.retry) {
      return result.status;
    }
    if (attempt === attempts) {
      throw new IndexNowError(`IndexNow ${attempts} denemede yanıt vermedi (son durum ${result.status}): ${result.detail} — adresler ${body.urlList.join(", ")}`);
    }
    console.warn("indexnow_retry", { attempt, status: result.status, detail: result.detail.slice(0, 200) });
    await sleep(retryBaseDelayMs * 2 ** (attempt - 1));
  }
  throw new IndexNowError("IndexNow deneme döngüsü sonuçsuz bitti.");
}

/** Değişen yazıları bildirir. */
async function main(): Promise<void> {
  const urls: SitemapUrl[] = sitemapUrls(await readFile(join(distDir, "sitemap.xml"), "utf8"));
  const first: SitemapUrl | undefined = urls[0];
  if (first === undefined) {
    throw new IndexNowError("dist/sitemap.xml boş: önce `npm run build`.");
  }
  const origin: string = new URL(first.loc).origin;
  if (!origin.startsWith("https://")) {
    throw new IndexNowError(`Site haritası üretim derlemesine ait değil (${origin}): IndexNow yalnızca \`npm run build\` çıktısıyla çalışır.`);
  }
  const keyFile: string = join(distDir, `${indexNowKey}.txt`);
  const served: string = await readFile(keyFile, "utf8");
  if (served !== indexNowKey) {
    throw new IndexNowError(`Anahtar dosyası (${keyFile}) anahtarın kendisini içermiyor.`);
  }
  const since: string = new Date(Date.now() - dayMs).toISOString().slice(0, 10);
  const urlList: string[] = changedUrls(urls, origin, since);
  if (urlList.length === 0) {
    console.log("indexnow_nothing_changed", { since });
    return;
  }
  const host: string = new URL(origin).host;
  const status: number = await submit({ host, key: indexNowKey, keyLocation: `${origin}/${indexNowKey}.txt`, urlList });
  console.log("indexnow_submitted", { status, since, urls: urlList });
}

await main();

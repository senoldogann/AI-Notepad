// Derlenmiş siteyi (dist/) Cloudflare Pages gibi sunar: uzantısız adresler (`/tr/fiyat` → `tr/fiyat.html`), `_headers`
// başlıkları (CSP dahil) ve 404.html. Ekran görüntüleri ve Lighthouse gerçek başlıklarla bu sunucuya karşı çalışır.
// Kullanım: node scripts/serve.ts <kapı>
import { readFile } from "node:fs/promises";
import { type IncomingMessage, type ServerResponse, createServer } from "node:http";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { type Resolved, contentTypes, resolveDistFile } from "./dist.ts";

/** `_headers` dosyasındaki bir kural: yol kalıbı ve başlıkları. */
interface HeaderRule {
  readonly pattern: string;
  readonly headers: readonly (readonly [string, string])[];
}

const distDir: string = fileURLToPath(new URL("../dist/", import.meta.url));

/** `_headers` metnini kurallara ayırır. Saf fonksiyondur. */
export function parseHeaders(text: string): HeaderRule[] {
  const rules: { pattern: string; headers: [string, string][] }[] = [];
  for (const line of text.split("\n")) {
    if (line.trim() === "") {
      continue;
    }
    if (!line.startsWith(" ")) {
      rules.push({ pattern: line.trim(), headers: [] });
      continue;
    }
    const separator: number = line.indexOf(":");
    const current = rules.at(-1);
    if (current === undefined || separator < 0) {
      throw new Error(`_headers satırı kurala bağlı değil ya da ":" yok: ${JSON.stringify(line)}`);
    }
    current.headers.push([line.slice(0, separator).trim(), line.slice(separator + 1).trim()]);
  }
  return rules;
}

/** Yol kalıba uyuyor mu (yalnızca sondaki `*` desteklenir; Pages'in kullandığımız kısmı). Saf fonksiyondur. */
function matches(pattern: string, path: string): boolean {
  return pattern.endsWith("*") ? path.startsWith(pattern.slice(0, -1)) : pattern === path;
}

/**
 * Adrese uyan kuralların başlıkları. Pages gibi, birden çok kuralda geçen başlığın değerleri virgülle birleştirilir
 * (CSP'de bu, birlikte uygulanan iki politika demektir). Saf fonksiyondur.
 */
export function matchedHeaders(rules: readonly HeaderRule[], path: string): Map<string, string> {
  const headers: Map<string, string> = new Map<string, string>();
  for (const rule of rules.filter((candidate: HeaderRule): boolean => matches(candidate.pattern, path))) {
    for (const [name, value] of rule.headers) {
      const previous: string | undefined = headers.get(name);
      headers.set(name, previous === undefined ? value : `${previous}, ${value}`);
    }
  }
  return headers;
}

/** Sunucuyu başlatır. */
async function main(): Promise<void> {
  const port: number = Number(process.argv[2]);
  if (!Number.isInteger(port) || port <= 0) {
    throw new Error(`Kapı numarası gerekli: node scripts/serve.ts <kapı> (gelen: ${JSON.stringify(process.argv[2] ?? null)})`);
  }
  const rules: HeaderRule[] = parseHeaders(await readFile(join(distDir, "_headers"), "utf8"));
  const server = createServer((request: IncomingMessage, response: ServerResponse): void => {
    const pathname: string = new URL(request.url ?? "/", "http://localhost").pathname;
    resolveDistFile(distDir, pathname)
      .then(async (resolved: Resolved): Promise<void> => {
        const body: Buffer = await readFile(resolved.file);
        response.statusCode = resolved.status;
        response.setHeader("content-type", contentTypes[extname(resolved.file)] ?? "application/octet-stream");
        for (const [name, value] of matchedHeaders(rules, pathname)) {
          // Yerelde https yok: tarayıcı http'yi https'e yükseltmeye çalışmasın.
          if (name !== "Strict-Transport-Security") {
            response.setHeader(name, value.replaceAll("; upgrade-insecure-requests", ""));
          }
        }
        response.end(body);
      })
      .catch((error: unknown): void => {
        console.error("serve_failed", { pathname, error: error instanceof Error ? error.message : String(error) });
        response.statusCode = 500;
        response.end();
      });
  });
  server.listen(port, "localhost", (): void => {
    console.log("serving", { url: `http://localhost:${port}`, dist: distDir });
  });
}

await main();

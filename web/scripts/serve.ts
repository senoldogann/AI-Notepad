// Derlenmiş siteyi (dist/) Cloudflare Pages gibi sunar: uzantısız adresler (`/tr/fiyat` → `tr/fiyat.html`), `_headers`
// başlıkları (CSP dahil) ve 404.html. Ekran görüntüleri ve Lighthouse gerçek başlıklarla bu sunucuya karşı çalışır.
// Kullanım: node scripts/serve.ts <kapı>
import { readFile, stat } from "node:fs/promises";
import { type IncomingMessage, type ServerResponse, createServer } from "node:http";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

/** `_headers` dosyasındaki bir kural: yol kalıbı ve başlıkları. */
interface HeaderRule {
  readonly pattern: string;
  readonly headers: readonly (readonly [string, string])[];
}

/** Sunulacak dosya ve durum kodu. */
interface Resolved {
  readonly file: string;
  readonly status: number;
}

const distDir: string = fileURLToPath(new URL("../dist/", import.meta.url));

const contentTypes: Readonly<Record<string, string>> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
};

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

/** Dosya var mı. */
async function isFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch (error: unknown) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

/** Adresi dist içindeki dosyaya çevirir (Pages kuralları: önce dosya, sonra `.html`, sonra `index.html`, yoksa 404). */
async function resolve(pathname: string): Promise<Resolved> {
  const safe: string = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, "");
  const base: string = join(distDir, safe);
  for (const candidate of [base, `${base.replace(/\/$/, "")}.html`, join(base, "index.html")]) {
    if (candidate.startsWith(distDir) && (await isFile(candidate))) {
      return { file: candidate, status: 200 };
    }
  }
  return { file: join(distDir, "404.html"), status: 404 };
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
    resolve(pathname)
      .then(async (resolved: Resolved): Promise<void> => {
        const body: Buffer = await readFile(resolved.file);
        response.statusCode = resolved.status;
        response.setHeader("content-type", contentTypes[extname(resolved.file)] ?? "application/octet-stream");
        for (const rule of rules.filter((candidate: HeaderRule): boolean => matches(candidate.pattern, pathname))) {
          for (const [name, value] of rule.headers) {
            // Yerelde https yok: tarayıcı http'yi https'e yükseltmeye çalışmasın.
            if (name !== "Strict-Transport-Security") {
              response.setHeader(name, value.replace("; upgrade-insecure-requests", ""));
            }
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

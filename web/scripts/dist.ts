// Derlenmiş sitenin (dist/) dosyalarını Cloudflare Pages kurallarıyla bulur: önce dosyanın kendisi, sonra `.html`,
// sonra `index.html`, yoksa 404.html. Yerel sunucu (serve.ts) ve paylaşım görseli üreticisi (make-blog-og.ts) kullanır.
import { stat } from "node:fs/promises";
import { join, normalize } from "node:path";

/** Sunulacak dosya ve durum kodu. */
export interface Resolved {
  readonly file: string;
  readonly status: number;
}

/** Uzantıya göre içerik türü. */
export const contentTypes: Readonly<Record<string, string>> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".mp4": "video/mp4",
  ".webp": "image/webp",
  ".avif": "image/avif",
  ".woff2": "font/woff2",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
};

/** Dosya var mı (yoksa false; başka okuma hatası fırlatılır). */
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

/** Adresi `distDir` (sonda `/`) içindeki dosyaya çevirir; klasörün dışına çıkan yol 404 olur. */
export async function resolveDistFile(distDir: string, pathname: string): Promise<Resolved> {
  const safe: string = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, "");
  const base: string = join(distDir, safe);
  for (const candidate of [base, `${base.replace(/\/$/, "")}.html`, join(base, "index.html")]) {
    if (candidate.startsWith(distDir) && (await isFile(candidate))) {
      return { file: candidate, status: 200 };
    }
  }
  return { file: join(distDir, "404.html"), status: 404 };
}

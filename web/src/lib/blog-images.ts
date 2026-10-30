// Blog yazılarındaki görseller: yönetim panelinin yüklediği WebP dosyaları (`public/blog/<kısa ad>/<ad>.webp`,
// server/src/blog.ts). Markdown derlenirken her `<img>`e dosyadan okunan genişlik ve yükseklik (yer kayması olmaz),
// `loading="lazy"` ve `decoding="async"` yazılır. Görsel yalnızca yazının kendi klasöründen olabilir (yazı silinince
// klasör de silinir; CSP dış görsele izin vermez); başka adres ya da eksik/bozuk dosya derlemeyi açık bir hatayla durdurur.
import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";
import type { Element } from "hast";
import { type HastPluginDefinition, type HastVisitorContext, defineHastPlugin } from "satteri";

/** Görselin piksel boyutu. */
export interface ImageSize {
  readonly width: number;
  readonly height: number;
}

/** Yazıdaki görsel kurala uymuyor ya da dosyası okunamıyor. */
export class BlogImageError extends Error {
  override readonly name: string = "BlogImageError";
}

/** Yazı görselinin adresi: `/blog/<kısa ad>/<ad>.webp` (ad sunucudaki `blogImageNamePattern` ile aynı). */
const blogImageSrc: RegExp = /^\/blog\/([a-z0-9]+(?:-[a-z0-9]+)*)\/([a-z0-9-]+\.webp)$/;

/** Dört baytlık ASCII etiket mi. Saf fonksiyondur. */
function hasTag(bytes: Uint8Array, offset: number, tag: string): boolean {
  return [...tag].every((char: string, index: number): boolean => bytes[offset + index] === char.charCodeAt(0));
}

/** Küçük sonlu (little-endian) işaretsiz tamsayı. Saf fonksiyondur. */
function littleEndian(bytes: Uint8Array, offset: number, length: number): number {
  let value: number = 0;
  for (let index: number = length - 1; index >= 0; index -= 1) {
    value = value * 256 + (bytes[offset + index] ?? 0);
  }
  return value;
}

/**
 * WebP dosyasının boyutu (RIFF başlığı ve ilk parça: `VP8 ` kayıplı, `VP8L` kayıpsız, `VP8X` genişletilmiş). WebP
 * değilse ya da başlık kısaysa `BlogImageError`. Sunucudaki `webpDimensions` aynı kuralları uygular. Saf fonksiyondur.
 */
export function webpSize(bytes: Uint8Array): ImageSize {
  if (bytes.length < 30 || !hasTag(bytes, 0, "RIFF") || !hasTag(bytes, 8, "WEBP")) {
    throw new BlogImageError(`WebP değil: RIFF/WEBP başlığı yok (${bytes.length} bayt).`);
  }
  if (hasTag(bytes, 12, "VP8 ")) {
    return { width: littleEndian(bytes, 26, 2) & 0x3fff, height: littleEndian(bytes, 28, 2) & 0x3fff };
  }
  if (hasTag(bytes, 12, "VP8L")) {
    const bits: number = littleEndian(bytes, 21, 4);
    return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  if (hasTag(bytes, 12, "VP8X")) {
    return { width: littleEndian(bytes, 24, 3) + 1, height: littleEndian(bytes, 27, 3) + 1 };
  }
  throw new BlogImageError("WebP'nin ilk parçası VP8, VP8L ya da VP8X değil.");
}

/** Markdown dosyasının kısa adı (`src/content/blog/<kısa ad>.md`). */
function postSlug(context: HastVisitorContext): string {
  if (context.fileURL === undefined) {
    throw new BlogImageError("Markdown dosyasının adresi yok: görselin hangi yazıya ait olduğu bilinemiyor.");
  }
  return basename(fileURLToPath(context.fileURL), ".md");
}

/**
 * Markdown görsellerine boyut ve tembel yükleme yazan Sätteri eklentisi (astro.config.ts `markdown.processor`).
 * `publicDir`: sitenin `public/` klasörü.
 */
export function blogImagesPlugin(publicDir: URL): HastPluginDefinition {
  return defineHastPlugin({
    name: "gistsmith-blog-images",
    element: {
      filter: ["img"],
      visit(node: Readonly<Element>, context: HastVisitorContext): void {
        const src: unknown = node.properties["src"];
        const slug: string = postSlug(context);
        const match: RegExpExecArray | null = typeof src === "string" ? blogImageSrc.exec(src) : null;
        if (match === null || match[1] !== slug) {
          throw new BlogImageError(
            `src/content/blog/${slug}.md: görsel adresi ${JSON.stringify(src)} geçersiz; yalnızca yazının kendi klasöründeki WebP olabilir (/blog/${slug}/<ad>.webp, yönetim panelinden "Add image").`,
          );
        }
        const file: URL = new URL(`.${String(src)}`, publicDir);
        let bytes: Uint8Array;
        try {
          bytes = readFileSync(file);
        } catch (error: unknown) {
          throw new BlogImageError(`src/content/blog/${slug}.md: görsel dosyası okunamadı (${fileURLToPath(file)}): ${error instanceof Error ? error.message : String(error)}`);
        }
        const size: ImageSize = webpSize(bytes);
        context.setProperty(node, "width", size.width);
        context.setProperty(node, "height", size.height);
        context.setProperty(node, "loading", "lazy");
        context.setProperty(node, "decoding", "async");
      },
    },
  });
}

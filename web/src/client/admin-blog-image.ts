// Blog düzenleyicisinin görsel hazırlığı: seçilen PNG, JPEG ya da WebP tarayıcıda en çok 1600 px genişliğe küçültülür ve
// tuvalden (canvas) WebP'ye çevrilir; 600 KB'ı aşan sonuç yüklenmez. Dosya adı alternatif metinden türetilir; Markdown
// bağlantısı imlecin olduğu yere kendi paragrafı olarak eklenir. Sunucu aynı sınırları yeniden denetler
// (server/src/blog.ts `decodeBlogImage`).

/** Görselin en büyük genişliği (piksel; sunucu `blogImageMaxWidth`). */
export const blogImageMaxWidth: number = 1600;
/** Sıkıştırılmış görselin en büyük boyu (bayt; sunucu `blogImageMaxBytes`). */
export const blogImageMaxBytes: number = 600 * 1024;
/** WebP kalitesi (0–1): ekran görüntüsü ve fotoğrafta görünür kayıp olmadan küçük. */
const webpQuality: number = 0.82;
/** Kabul edilen dosya türleri (`<input accept>` ile aynı). */
export const blogImageTypes: readonly string[] = ["image/png", "image/jpeg", "image/webp"];
/** Görsel adı (sunucu `blogImageNamePattern`, en çok 80 karakter). */
const imageNamePattern: RegExp = /^[a-z0-9-]+\.webp$/;
const imageNameMaxLength: number = 80;

/** Görsel hazırlanamadı: türü desteklenmiyor, çözülemedi, tarayıcı WebP yazamıyor ya da sonuç sınırı aşıyor. */
export class BlogImagePrepareError extends Error {
  override readonly name: string = "BlogImagePrepareError";
  readonly kind: "type" | "decode" | "encode" | "size";
  /** `size` hatasında sıkıştırılmış boyut (bayt); diğerlerinde 0. */
  readonly bytes: number;

  constructor(kind: "type" | "decode" | "encode" | "size", bytes: number, message: string) {
    super(message);
    this.kind = kind;
    this.bytes = bytes;
  }
}

/** Görselin piksel boyutu. */
export interface PixelSize {
  readonly width: number;
  readonly height: number;
}

/** Yüklenmeye hazır görsel. */
export interface PreparedImage {
  readonly blob: Blob;
  readonly width: number;
  readonly height: number;
}

/** Küçültülmüş boyut: genişlik en çok `maxWidth`, oran korunur, en az 1 piksel. Saf fonksiyondur. */
export function scaledSize(width: number, height: number, maxWidth: number): PixelSize {
  if (width <= maxWidth) {
    return { width, height };
  }
  return { width: maxWidth, height: Math.max(1, Math.round((height * maxWidth) / width)) };
}

/** Alternatif metinden dosya adı: aksansız küçük harf, tireli, en çok 75 karakter + `.webp`; boşsa `image.webp`. Saf fonksiyondur. */
export function imageNameFromAlt(alt: string): string {
  const base: string = alt
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replaceAll("ı", "i")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, imageNameMaxLength - ".webp".length)
    .replace(/-+$/, "");
  return `${base === "" ? "image" : base}.webp`;
}

/** Dosya adı sunucunun kuralına uyuyor mu. Saf fonksiyondur. */
export function isImageName(name: string): boolean {
  return name.length <= imageNameMaxLength && imageNamePattern.test(name);
}

/** Markdown görsel bağlantısı; alternatif metindeki köşeli parantez ve ters bölü kaçırılır. Saf fonksiyondur. */
export function imageMarkdown(alt: string, path: string): string {
  return `![${alt.replace(/[\\[\]]/g, "\\$&")}](${path})`;
}

/** Ekleme sonrası metin ve imlecin yeni yeri. */
export interface Insertion {
  readonly text: string;
  readonly cursor: number;
}

/**
 * Parçayı seçimin yerine kendi paragrafı olarak ekler: önünde ve arkasında gerekli kadar boş satır olur (metnin başı ve
 * sonu hariç). İmleç parçadan sonraya gelir. Saf fonksiyondur.
 */
export function insertBlock(text: string, start: number, end: number, block: string): Insertion {
  const before: string = text.slice(0, start);
  const after: string = text.slice(end);
  const leading: string = before === "" || before.endsWith("\n\n") ? "" : before.endsWith("\n") ? "\n" : "\n\n";
  const trailing: string = after === "" || after.startsWith("\n\n") ? "" : after.startsWith("\n") ? "\n" : "\n\n";
  const inserted: string = `${leading}${block}${trailing}`;
  return { text: `${before}${inserted}${after}`, cursor: before.length + leading.length + block.length };
}

/** Tuvali WebP'ye çevirir; tarayıcı WebP yazamıyorsa (ör. Safari PNG'ye düşer) `encode` hatası. */
function canvasWebp(canvas: HTMLCanvasElement): Promise<Blob> {
  return new Promise((resolve: (blob: Blob) => void, reject: (error: BlogImagePrepareError) => void): void => {
    canvas.toBlob(
      (blob: Blob | null): void => {
        if (blob === null || blob.type !== "image/webp") {
          reject(new BlogImagePrepareError("encode", 0, `Tarayıcı WebP yazamadı (çıktı ${blob === null ? "yok" : blob.type}).`));
          return;
        }
        resolve(blob);
      },
      "image/webp",
      webpQuality,
    );
  });
}

/** Dosyayı küçültür ve WebP'ye çevirir; sınır dışı sonuç ya da desteklenmeyen dosya `BlogImagePrepareError`. */
export async function prepareImage(file: File): Promise<PreparedImage> {
  if (!blogImageTypes.includes(file.type)) {
    throw new BlogImagePrepareError("type", 0, `Desteklenmeyen dosya türü: ${file.type === "" ? "bilinmiyor" : file.type}.`);
  }
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch (error: unknown) {
    throw new BlogImagePrepareError("decode", 0, `Görsel çözülemedi: ${error instanceof Error ? error.message : String(error)}`);
  }
  const size: PixelSize = scaledSize(bitmap.width, bitmap.height, blogImageMaxWidth);
  const canvas: HTMLCanvasElement = document.createElement("canvas");
  canvas.width = size.width;
  canvas.height = size.height;
  const context: CanvasRenderingContext2D | null = canvas.getContext("2d");
  if (context === null) {
    bitmap.close();
    throw new BlogImagePrepareError("encode", 0, "Tuval çizim bağlamı açılamadı.");
  }
  context.imageSmoothingQuality = "high";
  context.drawImage(bitmap, 0, 0, size.width, size.height);
  bitmap.close();
  const blob: Blob = await canvasWebp(canvas);
  if (blob.size > blogImageMaxBytes) {
    throw new BlogImagePrepareError("size", blob.size, `WebP ${blob.size} bayt; en çok ${blogImageMaxBytes}.`);
  }
  return { blob, width: size.width, height: size.height };
}

/** Görselin standart base64'ü (dolgulu; sunucuya JSON gövdesinde gider). */
export async function blobBase64(blob: Blob): Promise<string> {
  const bytes: Uint8Array = new Uint8Array(await blob.arrayBuffer());
  const chunk: number = 0x8000;
  let binary: string = "";
  for (let offset: number = 0; offset < bytes.length; offset += chunk) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunk));
  }
  return btoa(binary);
}

// Paylaşım görsellerinin (1200×630) ortak parçaları: logo çizimi (src/components/Logo.astro ile aynı) ve PNG'nin
// paletli kaydı. Chrome'un ekran görüntüsü gren yüzünden ~1,1 MB'tır; bazı önizleyiciler (ör. WhatsApp) 300 KB'tan büyük
// görseli atlar, bu yüzden görsel bütçeye sığan en çok renkli paletli PNG'ye indirilir (libimagequant, sharp).
// make-og.ts ve make-blog-og.ts kullanır.
import { mkdir, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import sharp, { type Metadata } from "sharp";

/** Paylaşım görselinin boyutu (src/lib/structured-data.ts `ogImageSize` ile aynı). */
export const ogViewport = { width: 1200, height: 630 } as const;

/** Uygulama simgesi (koyu karo, açık ses dalgası çubukları); `size` piksel. Saf fonksiyondur. */
export function logoSvg(size: number): string {
  return `<svg width="${size}" height="${size}" viewBox="0 0 32 32" aria-hidden="true"><rect x="0.5" y="0.5" width="31" height="31" rx="8.5" fill="#0a0a0a"/><g fill="#fafafa"><rect x="7.4" y="12" width="2.6" height="8" rx="1.3"/><rect x="11.4" y="8.2" width="2.6" height="15.6" rx="1.3"/><rect x="15.4" y="10.6" width="2.6" height="10.8" rx="1.3"/><rect x="19.6" y="14.7" width="5.6" height="2.6" rx="1.3"/></g></svg>`;
}

/** Görselin üst sınırı (bayt): bunu aşan paylaşım görseli bazı önizleyicilerde görünmez. */
const ogMaxBytes: number = 300 * 1024;

/** Paletin en çok renk sayısı ve libimagequant'ın hedef kalitesi (renk sayısını asıl kalite belirler). */
interface PaletteStep {
  readonly colors: number;
  readonly quality: number;
}

/** Denenen paletler (iyiden küçüğe): ilk bütçeye sığan kullanılır. */
const paletteSteps: readonly PaletteStep[] = [
  { colors: 128, quality: 90 },
  { colors: 96, quality: 85 },
  { colors: 64, quality: 80 },
  { colors: 48, quality: 75 },
  { colors: 32, quality: 70 },
];

/** Paylaşım görseli beklenen boyutta değil ya da en küçük paletle de bütçeye sığmıyor. */
export class OgImageError extends Error {
  override readonly name: string = "OgImageError";
}

/** Ekran görüntüsünü verilen paletle PNG'ye çevirir (titreşim yok: gren zaten gürültüdür). */
function palettePng(screenshot: Buffer, step: PaletteStep): Promise<Buffer> {
  return sharp(screenshot).png({ palette: true, colors: step.colors, quality: step.quality, dither: 0, effort: 10, compressionLevel: 9 }).toBuffer();
}

/**
 * Ekran görüntüsünü bütçeye (`ogMaxBytes`) sığan en çok renkli paletli PNG olarak yazar (klasörü gerekirse açar) ve
 * bayt boyunu döndürür. Boyut 1200×630 değilse ya da en küçük palet de sığmazsa `OgImageError`.
 */
export async function writeOgPng(screenshot: Buffer, path: string): Promise<number> {
  const metadata: Metadata = await sharp(screenshot).metadata();
  if (metadata.width !== ogViewport.width || metadata.height !== ogViewport.height) {
    throw new OgImageError(`Paylaşım görseli ${ogViewport.width}×${ogViewport.height} değil: ${String(metadata.width)}×${String(metadata.height)} (${path}).`);
  }
  const sizes: number[] = [];
  for (const step of paletteSteps) {
    const png: Buffer = await palettePng(screenshot, step);
    sizes.push(png.length);
    if (png.length <= ogMaxBytes) {
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, png);
      return png.length;
    }
  }
  throw new OgImageError(`Paylaşım görseli en küçük paletle de ${String(sizes.at(-1))} bayt; en çok ${ogMaxBytes} olmalı (${path}; denenen boylar ${sizes.join(", ")}).`);
}

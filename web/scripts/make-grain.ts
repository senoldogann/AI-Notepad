// Film greninin döşemesini (public/grain.png) üretir: scripts/grain.svg'deki SVG gürültü filtresi (feTurbulence)
// tarayıcıda bir kez çizilir ve 8 bit gri PNG olarak yazılır. Filtreyi sayfada canlı çizmek yavaş telefonda ana iş
// parçacığını ~2 sn tutuyordu (Lighthouse performansı 73); hazır döşeme aynı görünümü bedelsiz verir. Çıktı repoya
// girer, derleme bunu çalıştırmaz.
// Kullanım: node scripts/make-grain.ts <Chrome yolu>
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { crc32, deflateSync } from "node:zlib";
import { type Browser, type Page, chromium } from "playwright-core";

/** Döşemenin kenarı (piksel). */
const size: number = 180;

/** PNG parçası: uzunluk, tür, veri, CRC. Saf fonksiyondur. */
function chunk(type: string, data: Buffer): Buffer {
  const length: Buffer = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const typed: Buffer = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc: Buffer = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(typed));
  return Buffer.concat([length, typed, crc]);
}

/** 8 bit gri pikselleri PNG'ye çevirir. Saf fonksiyondur. */
export function grayPng(pixels: readonly number[], width: number, height: number): Buffer {
  const header: Buffer = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header.writeUInt8(8, 8); // bit derinliği
  header.writeUInt8(0, 9); // gri
  const rows: Buffer = Buffer.alloc((width + 1) * height);
  for (let y: number = 0; y < height; y += 1) {
    rows.writeUInt8(0, y * (width + 1)); // satır süzgeci: yok
    for (let x: number = 0; x < width; x += 1) {
      rows.writeUInt8(pixels[y * width + x] ?? 0, y * (width + 1) + 1 + x);
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(rows, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/** SVG'yi tarayıcıda tuvale çizer ve gri pikselleri döndürür. */
async function renderGray(page: Page, svg: string): Promise<number[]> {
  return page.evaluate(
    async ({ source, edge }: { readonly source: string; readonly edge: number }): Promise<number[]> => {
      const image: HTMLImageElement = new Image(edge, edge);
      image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(source)}`;
      await image.decode();
      const canvas: HTMLCanvasElement = document.createElement("canvas");
      canvas.width = edge;
      canvas.height = edge;
      const context: CanvasRenderingContext2D | null = canvas.getContext("2d");
      if (context === null) {
        throw new Error("2d tuval bağlamı alınamadı");
      }
      context.drawImage(image, 0, 0, edge, edge);
      const data: Uint8ClampedArray = context.getImageData(0, 0, edge, edge).data;
      const gray: number[] = [];
      for (let index: number = 0; index < data.length; index += 4) {
        gray.push(data[index] ?? 0);
      }
      return gray;
    },
    { source: svg, edge: size },
  );
}

/** Döşemeyi üretir ve yazar. */
async function main(): Promise<void> {
  const chromePath: string | undefined = process.argv[2];
  if (chromePath === undefined || chromePath === "") {
    throw new Error("Eksik bağımsız değişken: Chrome yolu. Kullanım: node scripts/make-grain.ts <chrome>");
  }
  const svg: string = await readFile(fileURLToPath(new URL("grain.svg", import.meta.url)), "utf8");
  const output: string = fileURLToPath(new URL("../public/grain.png", import.meta.url));
  const browser: Browser = await chromium.launch({ executablePath: chromePath, headless: true });
  try {
    const page: Page = await browser.newPage();
    await writeFile(output, grayPng(await renderGray(page, svg), size, size));
    console.log("grain_written", { output });
  } finally {
    await browser.close();
  }
}

await main();

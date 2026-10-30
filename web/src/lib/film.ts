// Uygulamanın film gradyanı ve kapak ses dalgasının site karşılığı (AINotepadUI/FilmGradient.swift,
// CoverBackground.swift). Ailelerin renkleri yalnızca global.css `.film--<aile>` kurallarındadır ve uygulamadaki
// `FilmPalette.colors` ile aynı kalmalıdır; dalga yükseklikleri uygulamadakiyle aynı sayıları üretir. Blog kapaklarının
// aile ve yerleşimi de buradan seçilir (`coverFilm`; site, yönetim paneli ve paylaşım görseli aynı sonucu kullanır).

/** Film gradyanının renk aileleri (global.css `.film--<aile>`). Blog yazısının `cover` ön bilgisi bunlardan biridir. */
export const filmPalettes = ["sunset", "coral", "ocean", "mint", "rose", "violet"] as const;

/** Film gradyanının renk ailesi. */
export type FilmPalette = (typeof filmPalettes)[number];

/** Bulutların yerleşimleri (global.css `.film--<yerleşim>`). */
export const filmLayouts = ["clouds-left", "clouds-right", "streaks"] as const;

/** Bulutların yerleşimi: yumuşak bulutlar (gölge solda ya da sağda) veya çapraz ışık süzmeleri. */
export type FilmLayout = (typeof filmLayouts)[number];

/** Bir kapağın gradyanı: renk ailesi ve yerleşim. */
export interface FilmCover {
  readonly palette: FilmPalette;
  readonly layout: FilmLayout;
}

/** Metnin 32 bitlik FNV-1a özeti (kapak seçimi için; güvenlik amaçlı değil). Saf fonksiyondur. */
function fnv1a(text: string): number {
  let hash: number = 0x811c9dc5;
  for (const char of text) {
    hash ^= char.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash;
}

/**
 * Tohumdan (blog yazısının kısa adı) sabit kapak: aile ve yerleşim özetten seçilir, aynı tohum her derlemede ve panelde
 * aynı kapağı verir. `palette` verilmişse (ön bilgideki `cover`) aile odur; yerleşim yine tohumdan gelir. Saf fonksiyondur.
 */
export function coverFilm(seed: string, palette: FilmPalette | null): FilmCover {
  const hash: number = fnv1a(seed);
  const chosen: FilmPalette | undefined = filmPalettes[hash % filmPalettes.length];
  const layout: FilmLayout | undefined = filmLayouts[(hash >>> 8) % filmLayouts.length];
  if (chosen === undefined || layout === undefined) {
    // Kalan her zaman dizinin içindedir; buraya gelinmesi listelerin boşaldığı anlamına gelir.
    throw new RangeError(`Kapak seçilemedi: aile ya da yerleşim listesi boş (tohum ${JSON.stringify(seed)}).`);
  }
  return { palette: palette ?? chosen, layout };
}

const mask64: bigint = (1n << 64n) - 1n;

/**
 * Kapak ses dalgasının çubuk yükseklikleri (0...1): tohumdan sabit, ortası yüksek, kenarlara doğru alçalan, komşularla
 * yumuşak geçişli. Uygulamadaki `coverWaveHeights` ile aynı sayı dizisini üretir (64 bit tamsayı aritmetiği). Saf
 * fonksiyondur.
 */
export function coverWaveHeights(seed: string, count: number): number[] {
  let state: bigint = 0x9e3779b97f4a7c15n;
  for (const char of seed) {
    state = ((state ^ BigInt(char.codePointAt(0) ?? 0)) * 0x100000001b3n) & mask64;
  }
  const raw: number[] = [];
  for (let index: number = 0; index < count; index += 1) {
    state = (state * 6364136223846793005n + 1442695040888963407n) & mask64;
    raw.push(Number(state >> 11n) / 2 ** 53);
  }
  return raw.map((value: number, index: number): number => {
    const previous: number = raw[Math.max(0, index - 1)] ?? value;
    const following: number = raw[Math.min(count - 1, index + 1)] ?? value;
    const smooth: number = (previous + 2 * value + following) / 4;
    const center: number = 1 - Math.abs(index / (count - 1) - 0.5) * 1.3;
    return 0.18 + 0.82 * smooth * center;
  });
}

/** Ses dalgasının bir çubuğu (SVG koordinatlarında). */
export interface WaveBar {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** Dalga çubuklarını verilen alana yerleştirir (uygulamadaki `CoverWaveform` çizimi). Saf fonksiyondur. */
export function waveBars(heights: readonly number[], width: number, height: number, gap: number): WaveBar[] {
  const barWidth: number = (width - gap * (heights.length - 1)) / heights.length;
  return heights.map((value: number, index: number): WaveBar => {
    const barHeight: number = Math.max(barWidth, value * height);
    return { x: index * (barWidth + gap), y: (height - barHeight) / 2, width: barWidth, height: barHeight };
  });
}

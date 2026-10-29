// Yasal metinlerin bölüm bilgisi: içindekiler ve bölüm başlıkları aynı diziden üretilir (layouts/Legal.astro,
// components/LegalSection.astro).

/** Bölümün çapası ve başlığı. */
export interface LegalSectionInfo {
  readonly id: string;
  readonly title: string;
}

/** Bölüm ve sıra numarası (1'den). */
export interface NumberedLegalSection {
  readonly section: LegalSectionInfo;
  readonly number: number;
}

/** Çapası bilinmeyen bölüm istendi: sayfadaki bölüm listesi ile metin uyuşmuyor. */
export class UnknownLegalSectionError extends Error {
  override readonly name: string = "UnknownLegalSectionError";
}

/** Bölüm listesinden çapası verilen bölümü numarasıyla döndürür; yoksa `UnknownLegalSectionError` (derleme durur). Saf fonksiyondur. */
export function numberedLegalSection(sections: readonly LegalSectionInfo[], id: string): NumberedLegalSection {
  const index: number = sections.findIndex((section: LegalSectionInfo): boolean => section.id === id);
  const section: LegalSectionInfo | undefined = sections[index];
  if (section === undefined) {
    throw new UnknownLegalSectionError(`Yasal metinde "${id}" bölümü tanımlı değil.`);
  }
  return { section, number: index + 1 };
}

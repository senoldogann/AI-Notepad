// Yönetim paneli tablolarının sütun tanımı (src/components/admin/TablePanel.astro). Sayısal sütunun başlığı da
// hücreleri de sağa yaslanır; betik hücreleri başlığa göre hizalar (admin-format.ts `fillTable`).

/** Tablo sütunu: başlık ve sayısal mı. */
export interface Column {
  readonly label: string;
  readonly numeric: boolean;
}

/** Metin sütunu. Saf fonksiyondur. */
export function textColumn(label: string): Column {
  return { label, numeric: false };
}

/** Sayı sütunu. Saf fonksiyondur. */
export function numberColumn(label: string): Column {
  return { label, numeric: true };
}

/** Kartın 12 sütunlu ızgarada kapladığı sütun sayısı. */
export type PanelSpan = 3 | 4 | 5 | 6 | 7 | 8 | 12;

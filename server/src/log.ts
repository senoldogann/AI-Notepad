/** Log alanı değerleri: yalnızca ilkel tipler; içerik, jeton ve anahtar yazılmaz. */
export type LogValue = string | number | boolean | null;

/** Yapılandırılmış log alanları. */
export type LogFields = Readonly<Record<string, LogValue>>;

/** Log düzeyi; `alert` harcama tavanı gibi insan müdahalesi isteyen durumlar içindir. */
export type LogLevel = "info" | "warn" | "error" | "alert";

/** Tek satır JSON log yazar; mesaj sabittir, değişken değerler alanlardadır. */
export function log(level: LogLevel, event: string, fields: LogFields): void {
  const line: string = JSON.stringify({ level, event, ...fields });
  if (level === "info") {
    console.log(line);
  } else if (level === "warn") {
    console.warn(line);
  } else {
    console.error(line);
  }
}

/** Bilinmeyen hatanın loglanabilir adı (mesajı değil: mesaj üst servis gövdesi taşıyabilir). Saf fonksiyondur. */
export function errorName(error: unknown): string {
  return error instanceof Error ? error.name : typeof error;
}

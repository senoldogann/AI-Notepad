/** Dizinin sınırları dışında okuma: çağıran yanlış dizin verdi. */
export class IndexOutOfRangeError extends Error {
  override readonly name: string = "IndexOutOfRangeError";
}

/** Dizideki öğeyi döngüsel dizinle döndürür (`index % uzunluk`); dizi boşsa `IndexOutOfRangeError`. Saf fonksiyondur. */
export function cyclic<T>(list: readonly T[], index: number): T {
  const item: T | undefined = list[index % list.length];
  if (item === undefined) {
    throw new IndexOutOfRangeError(`Boş diziden ${index}. öğe istendi.`);
  }
  return item;
}

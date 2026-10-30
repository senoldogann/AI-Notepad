// İndirme sayfası: yayınlanmış en son sürümün numarası sunucudan okunur (DMG ile aynı GitHub sürümündeki appcast;
// bkz. server/src/downloads.ts), böylece yeni sürüm çıkınca numara elle değiştirilmeden DMG ile birlikte güncellenir.
// Sürüm satırının yeri sayfada baştan ayrılmıştır (görünmez); okunamazsa öyle kalır ve hata konsola yazılır; indirme
// düğmesi numaradan bağımsız çalışır.
import { parseLatestVersion, send } from "./api";
import { element } from "./dom";

const versionPath: string = "/v1/download/mac/version";

/** Sürüm numarasını okuyup satırın değerine yazar ve satırı gösterir. */
async function main(): Promise<void> {
  const label: HTMLElement = element("download-version", HTMLElement);
  const value: HTMLElement = element("download-version-number", HTMLElement);
  const version: string = parseLatestVersion(
    await send({ method: "GET", path: versionPath, body: null, accessToken: null, attempts: 2 }),
    versionPath,
  );
  value.textContent = version;
  label.classList.remove("download-hero__pending");
  value.classList.remove("download-hero__pending");
}

main().catch((error: unknown): void => {
  console.error("download_version_failed", { path: versionPath, error: error instanceof Error ? error.message : String(error) });
});

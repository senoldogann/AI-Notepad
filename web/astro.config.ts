// Astro yapılandırması: durağan çıktı (Cloudflare Pages), sonda eğik çizgisiz adresler, satır içi betik ve stil yok
// (CSP 'unsafe-inline' istemez). Derleme sonunda `_headers` yapılandırmadan yazılır; yazı tipi lisansı ve uygulama
// simgesi uygulamanın dosyalarından kopyalanır (tek kaynak).
import { copyFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { satteri } from "@astrojs/markdown-satteri";
import { defineConfig } from "astro/config";
import type { AstroIntegration } from "astro";
import { type SiteConfig, parseWebTarget, siteConfigs } from "./src/config";
import { blogImagesPlugin } from "./src/lib/blog-images";
import { pagesHeaders } from "./src/lib/headers";

const config: SiteConfig = siteConfigs[parseWebTarget(process.env["PUBLIC_WEB_TARGET"])];

/** Uygulama klasöründen siteye kopyalanan dosyalar: kaynak (repo köküne göre) → hedef (çıktıya göre). */
const appFiles: readonly { readonly from: string; readonly to: string }[] = [
  { from: "App/Fonts/Inter-OFL.txt", to: "fonts/Inter-OFL.txt" },
  { from: "App/Assets.xcassets/AppIcon.appiconset/icon_256.png", to: "apple-touch-icon.png" },
];

/** Derleme sonunda Cloudflare Pages dosyalarını yazar ve uygulama dosyalarını kopyalar. */
function cloudflarePagesFiles(siteConfig: SiteConfig): AstroIntegration {
  return {
    name: "ainotepad-cloudflare-pages",
    hooks: {
      "astro:build:done": async ({ dir }: { dir: URL }): Promise<void> => {
        await writeFile(new URL("_headers", dir), pagesHeaders(siteConfig), "utf8");
        const repoRoot: URL = new URL("../", import.meta.url);
        for (const file of appFiles) {
          await copyFile(fileURLToPath(new URL(file.from, repoRoot)), fileURLToPath(new URL(file.to, dir)));
        }
      },
    },
  };
}

export default defineConfig({
  site: config.siteOrigin,
  output: "static",
  trailingSlash: "never",
  build: {
    format: "file",
    inlineStylesheets: "never",
  },
  vite: {
    build: {
      // Küçük betikler de dosya olarak çıkar: CSP satır içi betiğe izin vermez.
      assetsInlineLimit: 0,
    },
  },
  // Blog yazılarındaki kod blokları renklendirilmez: Shiki satır içi `style` yazar, CSP buna izin vermez. Görsellere
  // boyut ve tembel yükleme derlemede yazılır (src/lib/blog-images.ts).
  markdown: { syntaxHighlight: false, processor: satteri({ hastPlugins: [blogImagesPlugin(new URL("./public/", import.meta.url))] }) },
  devToolbar: { enabled: false },
  integrations: [cloudflarePagesFiles(config)],
});

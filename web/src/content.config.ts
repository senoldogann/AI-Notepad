// İçerik koleksiyonları: blog yazıları `src/content/blog/<kısa ad>.md` (kısa ad dosya adından gelir). Ön bilgi alanları
// derlemede doğrulanır; eksik ya da yanlış biçimli alan derlemeyi durdurur. Yönetim panelinin blog düzenleyicisi
// (server/src/blog.ts) aynı kuralları uygular ve dosyayı aynı alanlarla yazar; buradaki kural değişirse orada da değişmeli.
import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

const blog = defineCollection({
  loader: glob({ pattern: "*.md", base: "./src/content/blog" }),
  schema: z.object({
    /** Sayfa başlığı (h1) ve `<title>`'ın başı. */
    title: z.string().min(10).max(90),
    /** Meta açıklama ve dizindeki özet; arama sonuçlarında kesilmesin diye kısa. */
    description: z.string().min(50).max(170),
    author: z.string().min(1),
    /** Yayın tarihi (YYYY-AA-GG); derleme gününden (UTC) sonraysa yazı o güne dek yayımlanmaz (`isBlogPostPublic`). */
    published: z.coerce.date(),
    /** Taslak: derlemede hiçbir yerde (dizin, yazı sayfası, RSS, site haritası) yayımlanmaz. Her yazıda açıkça yazılır. */
    draft: z.boolean(),
  }),
});

export const collections = { blog };

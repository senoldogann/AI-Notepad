// Yönetim panelinin blog görünümü metinleri (İngilizce; yalnızca yönetici görür): menü, yazı listesi, haftalık düzen
// özeti, düzenleyici (kapak seçici, güncelleme günü, görsel ekleme), önizleme, kayıt ve silme sonuçları, sitede açma,
// paylaşım ve hatalar. Sayfa (admin.astro) ve betik (admin-blog.ts) aynı nesneyi kullanır; DOM'a dokunmaz.
import type { FilmPalette } from "../lib/film";

/** Yazının durumu (sunucu `BlogPostStatus`). */
export type BlogStatusKey = "draft" | "scheduled" | "live";

/** Görsel ekleme bölümünün metinleri. */
export interface BlogImageCopy {
  readonly add: string;
  readonly title: string;
  readonly file: string;
  readonly fileHint: string;
  readonly choose: string;
  readonly alt: string;
  readonly altHint: string;
  readonly name: string;
  readonly upload: string;
  readonly uploading: string;
  readonly cancel: string;
  /** `{folder}`: yazının görsel klasörü. Yeni (kaydedilmemiş) yazıda görsel eklenemez. */
  readonly saveFirst: string;
  /** `{width}`, `{height}`, `{size}` (KB): tarayıcıda küçültülmüş WebP. */
  readonly ready: string;
  readonly preparing: string;
  readonly inserted: string;
}

/** Blog görünümü metinleri. `{ad}` yer tutucuları değerlerle doldurulur. */
export interface AdminBlogCopy {
  /** Menüdeki ad ve görünüm başlığı. */
  readonly view: string;
  readonly listTitle: string;
  readonly newPost: string;
  /** Blog dizinini yeni sekmede açan bağlantı. */
  readonly openBlog: string;
  /** Yayındaki yazıyı yeni sekmede açan bağlantının adı (simge düğmesinde erişilebilir ad). */
  readonly openOnSite: string;
  readonly cadenceTitle: string;
  /** `{date}`, `{status}`: en son yayında ya da zamanlanmış yazı. */
  readonly cadenceLatest: string;
  readonly cadenceNone: string;
  /** `{date}`: önümüzdeki 7 gündeki ilk zamanlanmış yazı. */
  readonly cadenceNext: string;
  readonly cadenceGap: string;
  readonly columns: { readonly title: string; readonly status: string; readonly date: string; readonly author: string };
  readonly empty: string;
  /** Durum rozetleri; zamanlanmış rozette `{date}`. */
  readonly statuses: Readonly<Record<BlogStatusKey, string>>;
  /** Tarihsiz durum adları (haftalık düzen satırında tarih zaten yazılıdır). */
  readonly statusNames: Readonly<Record<BlogStatusKey, string>>;
  readonly back: string;
  readonly newTitle: string;
  readonly editTitle: string;
  readonly fields: {
    readonly title: string;
    readonly slug: string;
    readonly description: string;
    readonly author: string;
    readonly published: string;
    readonly updated: string;
    readonly cover: string;
    readonly draft: string;
    readonly body: string;
  };
  /** `{url}`: yazının adresi. */
  readonly slugHint: string;
  readonly slugLocked: string;
  readonly publishedHint: string;
  readonly updatedHint: string;
  readonly draftHint: string;
  /** Kapak seçicide "otomatik" seçeneği. */
  readonly coverAuto: string;
  /** `{palette}`: otomatik seçimin kısa addan seçtiği aile. */
  readonly coverAutoHint: string;
  readonly coverHint: string;
  /** Film ailelerinin adları. */
  readonly paletteNames: Readonly<Record<FilmPalette, string>>;
  readonly image: BlogImageCopy;
  /** `{count}`, `{min}`, `{max}`: karakter sayacı. */
  readonly counter: string;
  readonly write: string;
  readonly preview: string;
  readonly previewEmpty: string;
  /** `{alt}`: önizlemede gösterilmeyen dış görsel. */
  readonly previewImage: string;
  readonly save: string;
  readonly saving: string;
  readonly delete: string;
  readonly deleteConfirm: string;
  readonly deleteYes: string;
  readonly deleteNo: string;
  readonly deleting: string;
  /** Kayıt sonucu durumuna göre; zamanlanmışta `{date}`. */
  readonly saved: Readonly<Record<BlogStatusKey, string>>;
  readonly deleted: string;
  readonly shareTitle: string;
  readonly share: { readonly x: string; readonly linkedin: string; readonly bluesky: string };
  /** Kayıttan önce panelde denetlenen alanlar (sunucu aynı kuralları uygular). */
  readonly problems: {
    readonly title: string;
    readonly slug: string;
    readonly description: string;
    readonly author: string;
    readonly published: string;
    readonly body: string;
    readonly lineBreak: string;
    readonly updated: string;
    readonly imageFile: string;
    readonly imageAlt: string;
    readonly imageName: string;
    /** `{size}`: sıkıştırılmış boyut (KB). */
    readonly imageTooLarge: string;
    readonly imageEncode: string;
    readonly imageDecode: string;
  };
  /** Blog uçlarının hata kodlarına göre metinler (`invalid`, `imageRejected`: `{message}`). */
  readonly errors: {
    readonly unavailable: string;
    readonly exists: string;
    readonly conflict: string;
    readonly invalid: string;
    readonly github: string;
    readonly imageExists: string;
    readonly imagePostMissing: string;
    readonly imageRejected: string;
  };
}

export const adminBlogCopy: AdminBlogCopy = {
  view: "Blog",
  listTitle: "Posts",
  newPost: "New post",
  openBlog: "Open blog",
  openOnSite: "Open on site",
  cadenceTitle: "Weekly cadence",
  cadenceLatest: "Latest post: {date} · {status}",
  cadenceNone: "No live or scheduled posts yet.",
  cadenceNext: "Next one goes out {date}.",
  cadenceGap: "Nothing is scheduled for the next 7 days. Schedule a post to keep the weekly rhythm.",
  columns: { title: "Title", status: "Status", date: "Date", author: "Author" },
  empty: "No posts yet. Write the first one.",
  statuses: { draft: "Draft", scheduled: "Scheduled {date}", live: "Live" },
  statusNames: { draft: "Draft", scheduled: "Scheduled", live: "Live" },
  back: "All posts",
  newTitle: "New post",
  editTitle: "Edit post",
  fields: {
    title: "Title",
    slug: "URL slug",
    description: "Description",
    author: "Author",
    published: "Publish date",
    updated: "Last updated",
    cover: "Cover",
    draft: "Draft",
    body: "Post",
  },
  slugHint: "{url}",
  slugLocked: "The address stays the same once a post exists.",
  publishedHint: "Future dates go live with that day's 06:00 UTC build.",
  updatedHint: "Optional. Set it after a meaningful rewrite: search engines and the sitemap get the new date.",
  draftHint: "Drafts never appear on the site.",
  coverAuto: "Auto",
  coverAutoHint: "Auto picks {palette} for this address.",
  coverHint: "Shown on the post, the blog index and the share image.",
  paletteNames: { sunset: "Sunset", coral: "Coral", ocean: "Ocean", mint: "Mint", rose: "Rose", violet: "Violet" },
  image: {
    add: "Add image",
    title: "Add an image",
    file: "Image",
    choose: "Choose image",
    fileHint: "PNG, JPEG or WebP. It's resized to 1,600 px wide at most and saved as WebP (600 KB max).",
    alt: "Alt text",
    altHint: "Describe what the image shows. Screen readers and search engines read this.",
    name: "File name",
    upload: "Upload and insert",
    uploading: "Uploading…",
    cancel: "Cancel",
    saveFirst: "Save the post once to add images. They're stored next to it in {folder}.",
    ready: "{width} × {height} px · {size} KB WebP",
    preparing: "Preparing image…",
    inserted: "Image uploaded and inserted at the cursor. Save the post to publish it.",
  },
  counter: "{count} · {min}–{max}",
  write: "Write",
  preview: "Preview",
  previewEmpty: "Nothing to preview yet.",
  previewImage: "Image: {alt}",
  save: "Save",
  saving: "Saving…",
  delete: "Delete",
  deleteConfirm: "Delete this post? It leaves the site with the next build.",
  deleteYes: "Delete post",
  deleteNo: "Keep it",
  deleting: "Deleting…",
  saved: {
    live: "Published — the site updates in a few minutes.",
    scheduled: "Scheduled for {date}.",
    draft: "Saved as draft.",
  },
  deleted: "Post deleted — the site updates in a few minutes.",
  shareTitle: "Share",
  share: { x: "Share on X", linkedin: "Share on LinkedIn", bluesky: "Share on Bluesky" },
  problems: {
    title: "The title needs 10–90 characters.",
    slug: "The slug can only use lowercase letters, numbers and single dashes (up to 80 characters).",
    description: "The description needs 50–170 characters.",
    author: "Add an author.",
    published: "Pick a publish date.",
    body: "Write the post (up to 60,000 characters).",
    lineBreak: "Title, description and author must be a single line.",
    updated: "The last-updated date can't be before the publish date.",
    imageFile: "Pick a PNG, JPEG or WebP image.",
    imageAlt: "Add alt text for the image.",
    imageName: "Use lowercase letters, numbers and dashes for the file name, ending in .webp (up to 80 characters).",
    imageTooLarge: "The image is {size} KB after compression; the limit is 600 KB. Crop it or pick a simpler image.",
    imageEncode: "This browser can't save WebP images. Use Chrome, Edge or Firefox.",
    imageDecode: "This file couldn't be read as an image.",
  },
  errors: {
    unavailable: "Blog publishing isn't set up yet: the API needs the GITHUB_BLOG_TOKEN secret.",
    exists: "A post with this slug already exists. Pick another slug.",
    conflict: "This post changed since you opened it. Go back to all posts and open it again.",
    invalid: "A post in the repository can't be read: {message}",
    github: "GitHub didn't accept the request. Check the token's access to the repository and try again.",
    imageExists: "This post already has an image with that file name. Pick another name.",
    imagePostMissing: "This post isn't in the repository yet. Save it, then add the image.",
    imageRejected: "The server didn't accept the image: {message}",
  },
};

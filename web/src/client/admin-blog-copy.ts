// Yönetim panelinin blog görünümü metinleri (İngilizce; yalnızca yönetici görür): menü, yazı listesi, haftalık düzen
// özeti, düzenleyici, önizleme, kayıt ve silme sonuçları, paylaşım ve hatalar. Sayfa (admin.astro) ve betik
// (admin-blog.ts) aynı nesneyi kullanır; DOM'a dokunmaz.

/** Yazının durumu (sunucu `BlogPostStatus`). */
export type BlogStatusKey = "draft" | "scheduled" | "live";

/** Blog görünümü metinleri. `{ad}` yer tutucuları değerlerle doldurulur. */
export interface AdminBlogCopy {
  /** Menüdeki ad ve görünüm başlığı. */
  readonly view: string;
  readonly listTitle: string;
  readonly newPost: string;
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
    readonly draft: string;
    readonly body: string;
  };
  /** `{url}`: yazının adresi. */
  readonly slugHint: string;
  readonly slugLocked: string;
  readonly publishedHint: string;
  readonly draftHint: string;
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
  };
  /** Blog uçlarının hata kodlarına göre metinler (`invalid`: `{message}`). */
  readonly errors: {
    readonly unavailable: string;
    readonly exists: string;
    readonly conflict: string;
    readonly invalid: string;
    readonly github: string;
  };
}

export const adminBlogCopy: AdminBlogCopy = {
  view: "Blog",
  listTitle: "Posts",
  newPost: "New post",
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
    draft: "Draft",
    body: "Post",
  },
  slugHint: "{url}",
  slugLocked: "The address stays the same once a post exists.",
  publishedHint: "Future dates go live with that day's 06:00 UTC build.",
  draftHint: "Drafts never appear on the site.",
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
  },
  errors: {
    unavailable: "Blog publishing isn't set up yet: the API needs the GITHUB_BLOG_TOKEN secret.",
    exists: "A post with this slug already exists. Pick another slug.",
    conflict: "This post changed since you opened it. Go back to all posts and open it again.",
    invalid: "A post in the repository can't be read: {message}",
    github: "GitHub didn't accept the request. Check the token's access to the repository and try again.",
  },
};

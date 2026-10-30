// Yönetim panelinin blog görünümü: yazı listesi (durum rozeti, tarih, yazar), haftalık düzen özeti (en son yayında ya da
// zamanlanmış yazının tarihi; önümüzdeki 7 günde zamanlanmış yazı yoksa uyarı) ve düzenleyici (başlık, başlıktan
// türeyen kısa ad, karakter sayaçlı açıklama, yazar, yayın tarihi, taslak, Markdown gövde ve önizleme). Kayıt sunucuda
// GitHub'daki `web/src/content/blog/<kısa ad>.md` dosyasına yazılır; site her gün 06:00 UTC'de ve her kayıtta yeniden
// derlenir. Kayıttan sonra sonuç (yayında, zamanlanmış, taslak) ve yayındaki yazı için paylaşım bağlantıları gösterilir.
// Silme sayfa içinde onay ister (tarayıcı penceresi açılmaz).
import { ApiRequestError } from "./api";
import {
  type BlogPost,
  type BlogPostDraft,
  type BlogPostList,
  type BlogPostSummary,
  deleteBlogPost,
  fetchBlogPost,
  fetchBlogPosts,
  saveBlogPost,
} from "./admin-api";
import { type AdminBlogCopy, adminBlogCopy } from "./admin-blog-copy";
import { markdownPreview } from "./admin-blog-markdown";
import { fillTable, formatDayLong, node, pill, tableRow } from "./admin-format";
import { fill } from "./copy";
import { element, hideNotice, showNotice } from "./dom";
import { blogPostPath } from "../routes";
import { siteConfig } from "../site";

const blogText: AdminBlogCopy = adminBlogCopy;

const dayMs: number = 86_400_000;

/** Alan sınırları (sunucu `server/src/blog.ts` ve içerik şeması `web/src/content.config.ts` ile aynı). */
export const blogLimits = {
  title: { min: 10, max: 90 },
  description: { min: 50, max: 170 },
  slugMax: 80,
  bodyMax: 60_000,
} as const;

const slugPattern: RegExp = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const dayPattern: RegExp = /^\d{4}-\d{2}-\d{2}$/;
/** Tek satırlık alanlarda yasak denetim karakterleri (sunucuyla aynı). */
const lineForbidden: RegExp = /[\u0000-\u001f\u007f-\u009f\ud800-\udfff]/u;

/** Blog görünümünün dışarıya açtığı işlemler. */
export interface BlogView {
  /** Listeyi (yeniden) yükler. */
  readonly refresh: () => Promise<void>;
  /** İlk açılışta yükler (sonrakilerde bir şey yapmaz). */
  readonly ensureLoaded: () => Promise<void>;
}

/** Düzenleyicideki alanların değerleri. */
export interface BlogForm {
  readonly title: string;
  readonly slug: string;
  readonly description: string;
  readonly author: string;
  readonly published: string;
  readonly draft: boolean;
  readonly body: string;
}

/** Haftalık düzen: en son yayında ya da zamanlanmış yazı, önümüzdeki 7 gündeki ilk yazı ve boşluk uyarısı. */
export interface BlogCadence {
  readonly latest: BlogPostSummary | null;
  readonly next: BlogPostSummary | null;
  readonly gap: boolean;
}

/** Paylaşım bağlantıları (yeni sekmede açılan hazır gönderi pencereleri). */
export interface ShareLinks {
  readonly x: string;
  readonly linkedin: string;
  readonly bluesky: string;
}

/** `YYYY-MM-DD` gününe gün ekler (UTC). Saf fonksiyondur. */
export function addDays(day: string, days: number): string {
  return new Date(Date.parse(`${day}T00:00:00Z`) + days * dayMs).toISOString().slice(0, 10);
}

/** Başlıktan kısa ad: aksanlar atılır, harf ve rakam dışı her şey tek tireye döner, en çok 80 karakter. Saf fonksiyondur. */
export function slugFromTitle(title: string): string {
  const plain: string = title
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replaceAll("ı", "i")
    .replaceAll("ß", "ss")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return plain.slice(0, blogLimits.slugMax).replace(/-+$/, "");
}

/**
 * Haftalık düzen: taslak dışı yazıların en yenisi ve bugünden sonraki 7 gün içindeki (bugün hariç) ilk yazı; o aralıkta
 * yazı yoksa boşluk vardır. Saf fonksiyondur.
 */
export function blogCadence(posts: readonly BlogPostSummary[], today: string): BlogCadence {
  const planned: BlogPostSummary[] = posts.filter((post: BlogPostSummary): boolean => !post.draft);
  const latest: BlogPostSummary | null = planned.reduce(
    (best: BlogPostSummary | null, post: BlogPostSummary): BlogPostSummary => (best === null || post.published > best.published ? post : best),
    null,
  );
  const weekEnd: string = addDays(today, 7);
  const upcoming: BlogPostSummary[] = planned
    .filter((post: BlogPostSummary): boolean => post.published > today && post.published <= weekEnd)
    .sort((a: BlogPostSummary, b: BlogPostSummary): number => a.published.localeCompare(b.published));
  return { latest, next: upcoming[0] ?? null, gap: upcoming.length === 0 };
}

/** Yeni yazının önerilen tarihi: bugün ile en son yayında ya da zamanlanmış yazının 7 gün sonrasının büyüğü. Saf fonksiyondur. */
export function defaultPublishDate(posts: readonly BlogPostSummary[], today: string): string {
  const latest: BlogPostSummary | null = blogCadence(posts, today).latest;
  if (latest === null) {
    return today;
  }
  const next: string = addDays(latest.published, 7);
  return next > today ? next : today;
}

/** Yeni yazının önerilen yazarı: en yeni yazınınki (yazı yoksa boş). Saf fonksiyondur. */
export function defaultAuthor(posts: readonly BlogPostSummary[]): string {
  return posts[0]?.author ?? "";
}

/** Kayıttan önce denetlenen sorunlar (sunucu aynı kuralları uygular); boşsa kaydedilebilir. Saf fonksiyondur. */
export function blogFormProblems(form: BlogForm): string[] {
  const problems: string[] = [];
  const singleLine = (value: string): boolean => !lineForbidden.test(value);
  if (form.title.length < blogLimits.title.min || form.title.length > blogLimits.title.max) {
    problems.push(blogText.problems.title);
  }
  if (form.slug.length > blogLimits.slugMax || !slugPattern.test(form.slug)) {
    problems.push(blogText.problems.slug);
  }
  if (form.description.length < blogLimits.description.min || form.description.length > blogLimits.description.max) {
    problems.push(blogText.problems.description);
  }
  if (form.author === "") {
    problems.push(blogText.problems.author);
  }
  if (!singleLine(form.title) || !singleLine(form.description) || !singleLine(form.author)) {
    problems.push(blogText.problems.lineBreak);
  }
  if (!dayPattern.test(form.published) || Number.isNaN(Date.parse(`${form.published}T00:00:00Z`))) {
    problems.push(blogText.problems.published);
  }
  if (form.body.trim() === "" || form.body.length > blogLimits.bodyMax) {
    problems.push(blogText.problems.body);
  }
  return problems;
}

/** Yazının sitedeki mutlak adresi. Saf fonksiyondur. */
export function blogPostUrl(slug: string): string {
  return `${siteConfig.siteOrigin}${blogPostPath(slug)}`;
}

/** X, LinkedIn ve Bluesky'ın hazır gönderi adresleri. Saf fonksiyondur. */
export function shareLinks(url: string, title: string): ShareLinks {
  return {
    x: `https://x.com/intent/post?${new URLSearchParams({ text: title, url }).toString()}`,
    linkedin: `https://www.linkedin.com/sharing/share-offsite/?${new URLSearchParams({ url }).toString()}`,
    bluesky: `https://bsky.app/intent/compose?${new URLSearchParams({ text: `${title} ${url}` }).toString()}`,
  };
}

/** Durum rozetinin metni. Saf fonksiyondur. */
function statusText(post: BlogPostSummary): string {
  return post.status === "scheduled" ? fill(blogText.statuses.scheduled, { date: formatDayLong(post.published) }) : blogText.statuses[post.status];
}

/** Durum rozeti: yayında yeşil, zamanlanmış sarı, taslak nötr. */
function statusPill(post: BlogPostSummary): HTMLSpanElement {
  return pill(statusText(post), post.status === "live" ? "ok" : post.status === "scheduled" ? "warn" : "");
}

/** Blog uçlarının bilinen hatası için panelde gösterilecek metin; başka hatada null. Saf fonksiyondur. */
function blogErrorText(error: unknown): string | null {
  if (!(error instanceof ApiRequestError)) {
    return null;
  }
  switch (error.code) {
    case "blog_unavailable":
      return blogText.errors.unavailable;
    case "blog_post_exists":
      return blogText.errors.exists;
    case "blog_conflict":
      return blogText.errors.conflict;
    case "blog_post_invalid":
      return fill(blogText.errors.invalid, { message: error.message });
    case "upstream_rejected":
    case "upstream_unavailable":
      return blogText.errors.github;
    default:
      return null;
  }
}

/**
 * Bildirimi tonuyla gösterir (`ok`: başarı, `error`: hata) ve görünür alana kaydırır: telefonda kayıt düğmesi formun
 * altındadır, sonuç bildirimi üstte kalırdı.
 */
function showToned(notice: HTMLElement, message: string, tone: "ok" | "error"): void {
  notice.classList.toggle("notice--ok", tone === "ok");
  notice.classList.toggle("notice--error", tone === "error");
  showNotice(notice, message);
  notice.scrollIntoView({ block: "nearest" });
}

/** Karakter sayacını yazar; sınır dışındaysa uyarı görünümü. */
function renderCounter(id: string, length: number, min: number, max: number): void {
  const counter: HTMLElement = element(id, HTMLElement);
  counter.textContent = fill(blogText.counter, { count: String(length), min: String(min), max: String(max) });
  counter.classList.toggle("blog-counter--warn", length < min || length > max);
}

/** Düzenleyicinin durumu: açık yazı (yeni yazıda null), kısa ad elle değişti mi, kayıt ya da silme sürüyor mu. */
interface EditorState {
  post: BlogPost | null;
  slugEdited: boolean;
  busy: boolean;
}

/** Görünümün durumu. `openRequest` her yazı açılışında artar: geç gelen eski yazı çizilmez. */
interface BlogState {
  list: BlogPostList | null;
  loaded: boolean;
  /** Kayıt ya da silmeden sonra listeye dönülünce yeniden yüklenir. */
  stale: boolean;
  openRequest: number;
  editor: EditorState;
}

/** Düzenleyicinin alan öğeleri. */
interface EditorFields {
  readonly title: HTMLInputElement;
  readonly slug: HTMLInputElement;
  readonly description: HTMLTextAreaElement;
  readonly author: HTMLInputElement;
  readonly published: HTMLInputElement;
  readonly draft: HTMLInputElement;
  readonly body: HTMLTextAreaElement;
}

/** Alan öğelerini bulur. */
function editorFields(): EditorFields {
  return {
    title: element("blog-title", HTMLInputElement),
    slug: element("blog-slug", HTMLInputElement),
    description: element("blog-description", HTMLTextAreaElement),
    author: element("blog-author", HTMLInputElement),
    published: element("blog-published", HTMLInputElement),
    draft: element("blog-draft", HTMLInputElement),
    body: element("blog-body", HTMLTextAreaElement),
  };
}

/** Alanların değerleri (tek satırlık alanlar kırpılır). */
function readForm(fields: EditorFields): BlogForm {
  return {
    title: fields.title.value.trim(),
    slug: fields.slug.value.trim(),
    description: fields.description.value.trim(),
    author: fields.author.value.trim(),
    published: fields.published.value,
    draft: fields.draft.checked,
    body: fields.body.value,
  };
}

/** Haftalık düzen kutusunu çizer. */
function renderCadence(list: BlogPostList): void {
  const cadence: BlogCadence = blogCadence(list.posts, list.today);
  element("blog-cadence-latest", HTMLElement).textContent =
    cadence.latest === null
      ? blogText.cadenceNone
      : fill(blogText.cadenceLatest, { date: formatDayLong(cadence.latest.published), status: blogText.statusNames[cadence.latest.status] });
  element("blog-cadence-next", HTMLElement).textContent =
    cadence.next === null ? blogText.cadenceGap : fill(blogText.cadenceNext, { date: formatDayLong(cadence.next.published) });
  element("blog-cadence", HTMLElement).classList.toggle("kpi--warn", cadence.gap);
}

/** Listedeki yazının satırı: başlık (düzenleyiciyi açar) ve kısa ad, durum, tarih, yazar. */
function postRow(post: BlogPostSummary, onOpen: (slug: string) => void): HTMLTableRowElement {
  const title: HTMLButtonElement = node("button", "blog-row__title", post.title);
  title.type = "button";
  title.addEventListener("click", (): void => onOpen(post.slug));
  const cell: HTMLElement = node("div", "blog-row", "");
  cell.append(title, node("span", "blog-row__slug mono", blogPostPath(post.slug)));
  return tableRow([cell, statusPill(post), formatDayLong(post.published), post.author]);
}

/** Listeyi ve düzen kutusunu çizer. */
function renderList(list: BlogPostList, onOpen: (slug: string) => void): void {
  renderCadence(list);
  fillTable(
    element("blog-rows", HTMLTableSectionElement),
    list.posts.map((post: BlogPostSummary): HTMLTableRowElement => postRow(post, onOpen)),
  );
  element("blog-empty", HTMLElement).classList.toggle("hidden", list.posts.length > 0);
}

/** Paylaşım satırını yayındaki yazı için doldurur ve gösterir; başka durumda gizler. */
function renderShare(post: BlogPost | null): void {
  const row: HTMLElement = element("blog-share", HTMLElement);
  if (post === null || post.status !== "live") {
    row.classList.add("hidden");
    return;
  }
  const links: ShareLinks = shareLinks(blogPostUrl(post.slug), post.title);
  element("blog-share-x", HTMLAnchorElement).href = links.x;
  element("blog-share-linkedin", HTMLAnchorElement).href = links.linkedin;
  element("blog-share-bluesky", HTMLAnchorElement).href = links.bluesky;
  row.classList.remove("hidden");
}

/** Sayaçları ve kısa adın adres satırını yazar. */
function renderEditorHints(fields: EditorFields): void {
  renderCounter("blog-title-counter", fields.title.value.trim().length, blogLimits.title.min, blogLimits.title.max);
  renderCounter("blog-description-counter", fields.description.value.trim().length, blogLimits.description.min, blogLimits.description.max);
  element("blog-slug-url", HTMLElement).textContent = blogPostUrl(fields.slug.value.trim() === "" ? "…" : fields.slug.value.trim());
}

/** Önizlemeyi çizer: başlık, açıklama ve gövde. */
function renderPreview(fields: EditorFields): void {
  const form: BlogForm = readForm(fields);
  const preview: HTMLElement = element("blog-preview", HTMLElement);
  if (form.title === "" && form.body.trim() === "") {
    preview.replaceChildren(node("p", "muted", blogText.previewEmpty));
    return;
  }
  preview.replaceChildren(node("h1", "", form.title), node("p", "lead", form.description), ...markdownPreview(form.body, { image: blogText.previewImage }));
}

/** Yazma ya da önizleme sekmesini gösterir. */
function showEditorTab(fields: EditorFields, tab: "write" | "preview"): void {
  element("blog-tab-write", HTMLButtonElement).setAttribute("aria-pressed", String(tab === "write"));
  element("blog-tab-preview", HTMLButtonElement).setAttribute("aria-pressed", String(tab === "preview"));
  fields.body.classList.toggle("hidden", tab !== "write");
  element("blog-preview", HTMLElement).classList.toggle("hidden", tab !== "preview");
  if (tab === "preview") {
    renderPreview(fields);
  }
}

/** Düzenleyiciyi yazıyla (yeni yazıda null ve önerilen değerlerle) doldurur. */
function fillEditor(fields: EditorFields, post: BlogPost | null, suggested: { readonly author: string; readonly published: string }): void {
  fields.title.value = post?.title ?? "";
  fields.slug.value = post?.slug ?? "";
  fields.slug.readOnly = post !== null;
  fields.description.value = post?.description ?? "";
  fields.author.value = post?.author ?? suggested.author;
  fields.published.value = post?.published ?? suggested.published;
  fields.draft.checked = post?.draft ?? false;
  fields.body.value = post?.body ?? "";
  element("blog-editor-title", HTMLElement).textContent = post === null ? blogText.newTitle : blogText.editTitle;
  element("blog-slug-locked", HTMLElement).classList.toggle("hidden", post === null);
  const status: HTMLElement = element("blog-editor-status", HTMLElement);
  status.replaceChildren(...(post === null ? [] : [statusPill(post)]));
  element("blog-delete", HTMLButtonElement).classList.toggle("hidden", post === null);
  element("blog-delete-confirm", HTMLElement).classList.add("hidden");
  renderShare(post);
  renderEditorHints(fields);
  showEditorTab(fields, "write");
}

/** Liste ya da düzenleyici görünümünü gösterir ve kabuğun içeriğini başa kaydırır. */
function showBlogScreen(screen: "list" | "editor"): void {
  element("blog-list-view", HTMLElement).classList.toggle("hidden", screen !== "list");
  element("blog-editor-view", HTMLElement).classList.toggle("hidden", screen !== "editor");
  document.querySelector(".console__main")?.scrollTo(0, 0);
}

/** Blog görünümünü bağlar; blog uçlarının bilinen hataları panelde gösterilir, diğerleri `onFailure`'a gider. */
export function createBlogView(onFailure: (error: unknown) => void): BlogView {
  const state: BlogState = { list: null, loaded: false, stale: false, openRequest: 0, editor: { post: null, slugEdited: false, busy: false } };
  const fields: EditorFields = editorFields();
  const listNotice: HTMLElement = element("blog-notice", HTMLElement);
  const editorNotice: HTMLElement = element("blog-editor-notice", HTMLElement);

  /** Bilinen blog hatasını bildirime yazar; başkasını `onFailure`'a verir. */
  const report = (notice: HTMLElement, error: unknown): void => {
    const message: string | null = blogErrorText(error);
    if (message === null) {
      onFailure(error);
      return;
    }
    showToned(notice, message, "error");
  };

  const refresh = async (): Promise<void> => {
    try {
      const list: BlogPostList = await fetchBlogPosts();
      state.list = list;
      state.loaded = true;
      state.stale = false;
      hideNotice(listNotice);
      renderList(list, open);
      // Yeni yazının önerilen tarihi ve yazarı listeden gelir: liste yüklenmeden yeni yazı açılmaz.
      element("blog-new", HTMLButtonElement).disabled = false;
    } catch (error: unknown) {
      const message: string | null = blogErrorText(error);
      if (message === null) {
        throw error;
      }
      showToned(listNotice, message, "error");
    }
  };

  const openEditor = (post: BlogPost | null, list: BlogPostList): void => {
    state.editor = { post, slugEdited: post !== null, busy: false };
    hideNotice(editorNotice);
    fillEditor(fields, post, { author: defaultAuthor(list.posts), published: defaultPublishDate(list.posts, list.today) });
    showBlogScreen("editor");
  };

  function open(slug: string): void {
    const list: BlogPostList | null = state.list;
    if (list === null) {
      return;
    }
    state.openRequest += 1;
    const request: number = state.openRequest;
    hideNotice(listNotice);
    fetchBlogPost(slug)
      .then((post: BlogPost): void => {
        if (request === state.openRequest) {
          openEditor(post, list);
        }
      })
      .catch((error: unknown): void => {
        report(listNotice, error);
      });
  }

  const backToList = (): void => {
    state.openRequest += 1;
    showBlogScreen("list");
    if (state.stale) {
      refresh().catch(onFailure);
    }
  };

  /** Kayıt ya da silme sürerken düğmeler kapalıdır; kayıt düğmesi süren işi yazar. */
  const startBusy = (label: string): void => {
    state.editor.busy = true;
    const save: HTMLButtonElement = element("blog-save", HTMLButtonElement);
    save.disabled = true;
    save.textContent = label;
    element("blog-delete", HTMLButtonElement).disabled = true;
    element("blog-delete-yes", HTMLButtonElement).disabled = true;
  };

  const endBusy = (): void => {
    state.editor.busy = false;
    const save: HTMLButtonElement = element("blog-save", HTMLButtonElement);
    save.disabled = false;
    save.textContent = blogText.save;
    element("blog-delete", HTMLButtonElement).disabled = false;
    element("blog-delete-yes", HTMLButtonElement).disabled = false;
  };

  const save = (): void => {
    if (state.editor.busy) {
      return;
    }
    const form: BlogForm = readForm(fields);
    const problems: string[] = blogFormProblems(form);
    if (problems.length > 0) {
      showToned(editorNotice, problems.join(" "), "error");
      return;
    }
    const current: BlogPost | null = state.editor.post;
    const draft: BlogPostDraft = {
      title: form.title,
      description: form.description,
      author: form.author,
      published: form.published,
      draft: form.draft,
      body: form.body,
      sha: current?.sha ?? null,
    };
    hideNotice(editorNotice);
    startBusy(blogText.saving);
    saveBlogPost(form.slug, draft)
      .then((saved: BlogPost): void => {
        state.stale = true;
        fillEditor(fields, saved, { author: saved.author, published: saved.published });
        state.editor = { post: saved, slugEdited: true, busy: false };
        const message: string = saved.status === "scheduled" ? fill(blogText.saved.scheduled, { date: formatDayLong(saved.published) }) : blogText.saved[saved.status];
        showToned(editorNotice, message, "ok");
      })
      .catch((error: unknown): void => {
        report(editorNotice, error);
      })
      .finally(endBusy);
  };

  const confirmDelete = (): void => {
    const current: BlogPost | null = state.editor.post;
    if (current === null || state.editor.busy) {
      return;
    }
    startBusy(blogText.deleting);
    deleteBlogPost(current.slug, current.sha)
      .then(async (): Promise<void> => {
        state.editor = { post: null, slugEdited: false, busy: false };
        showBlogScreen("list");
        await refresh();
        showToned(listNotice, blogText.deleted, "ok");
      })
      .catch((error: unknown): void => {
        element("blog-delete-confirm", HTMLElement).classList.add("hidden");
        report(editorNotice, error);
      })
      .finally(endBusy);
  };

  element("blog-new", HTMLButtonElement).addEventListener("click", (): void => {
    if (state.list !== null) {
      openEditor(null, state.list);
    }
  });
  element("blog-back", HTMLButtonElement).addEventListener("click", backToList);
  fields.title.addEventListener("input", (): void => {
    if (!state.editor.slugEdited) {
      fields.slug.value = slugFromTitle(fields.title.value);
    }
    renderEditorHints(fields);
  });
  fields.slug.addEventListener("input", (): void => {
    state.editor.slugEdited = true;
    renderEditorHints(fields);
  });
  fields.description.addEventListener("input", (): void => renderEditorHints(fields));
  element("blog-tab-write", HTMLButtonElement).addEventListener("click", (): void => showEditorTab(fields, "write"));
  element("blog-tab-preview", HTMLButtonElement).addEventListener("click", (): void => showEditorTab(fields, "preview"));
  element("blog-form", HTMLFormElement).addEventListener("submit", (event: SubmitEvent): void => {
    event.preventDefault();
    save();
  });
  element("blog-delete", HTMLButtonElement).addEventListener("click", (): void => {
    element("blog-delete-confirm", HTMLElement).classList.remove("hidden");
    element("blog-delete-yes", HTMLButtonElement).focus();
  });
  element("blog-delete-no", HTMLButtonElement).addEventListener("click", (): void => {
    element("blog-delete-confirm", HTMLElement).classList.add("hidden");
    element("blog-delete", HTMLButtonElement).focus();
  });
  element("blog-delete-yes", HTMLButtonElement).addEventListener("click", confirmDelete);

  return {
    refresh,
    ensureLoaded: async (): Promise<void> => {
      if (!state.loaded) {
        await refresh();
      }
    },
  };
}

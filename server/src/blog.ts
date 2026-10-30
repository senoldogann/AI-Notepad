import { z } from "zod";
import type { BlogConfig } from "./config";
import { base64Decode, base64Encode, decodeUtf8Strict, utf8 } from "./crypto";
import { ApiError, ProviderApiError, UpstreamError } from "./errors";
import { errorName, log } from "./log";
import type { Platform } from "./platform";
import { withRetries } from "./retry";
import { isRetryableUpstreamError, isTimeoutError } from "./upstream";

/**
 * Yönetim panelinden blog yayını. Yazılar sitenin içerik koleksiyonudur (`web/src/content.config.ts`): GitHub
 * deposundaki `web/src/content/blog/<kısa ad>.md` dosyaları. Panel yazıyı GitHub'ın REST contents API'siyle okur, yazar
 * ve siler (her kayıt yapılandırılmış dala bir commit'tir); liste tek GraphQL isteğiyle okunur (yazı başına ayrı istek
 * Worker'ın alt istek sınırına takılırdı). Site her gün 06:00 UTC'de ve dala her gönderimde yeniden derlenir
 * (`.github/workflows/deploy-web.yml`); taslaklar ve tarihi gelmemiş yazılar derlemede yayımlanmaz.
 *
 * Alan kuralları içerik şemasıyla aynıdır (başlık 10–90, açıklama 50–170, yazar boş değil, tarih `YYYY-MM-DD`, isteğe
 * bağlı `updated` `published`'dan önce olmayan bir gün, isteğe bağlı `cover` film ailelerinden biri, taslak mantıksal);
 * ayrıca tek satırlık alanlarda denetim karakteri olamaz (ön bilgi YAML'ı güvenle yazılsın diye).
 *
 * Yazının görselleri `web/public/blog/<kısa ad>/<ad>.webp` dosyalarıdır (panel tarayıcıda WebP'ye çevirip yükler, site
 * `/blog/<kısa ad>/<ad>.webp` adresinden sunar). Yazı silinince klasörü de aynı commit'te silinir.
 */

/** Yazıların depodaki klasörü. */
export const blogDirectory: string = "web/src/content/blog";

/** Yazı görsellerinin depodaki kök klasörü (`<kök>/<kısa ad>/<ad>.webp`; sitede `/blog/<kısa ad>/<ad>.webp`). */
export const blogImageDirectory: string = "web/public/blog";

/**
 * Kapak renk aileleri: sitenin film gradyanı aileleri (`web/src/lib/film.ts` `filmPalettes`; eşleşmeyi blog testi
 * denetler).
 */
export const blogCoverPalettes = ["sunset", "coral", "ocean", "mint", "rose", "violet"] as const;

/** Kapak renk ailesi. */
export type BlogCoverPalette = (typeof blogCoverPalettes)[number];

/** Yazının durumu: taslak, tarihi gelecekte (zamanlanmış) ya da yayında (tarihi bugün ya da geçmişte, UTC). */
export type BlogPostStatus = "draft" | "scheduled" | "live";

/**
 * Yazının ön bilgisi (`published`, `updated`: `YYYY-MM-DD`). `updated` ve `cover` dosyada isteğe bağlıdır; yazılmamışsa
 * null (kapak kısa addan seçilir).
 */
export interface BlogFrontMatter {
  readonly title: string;
  readonly description: string;
  readonly author: string;
  readonly published: string;
  readonly updated: string | null;
  readonly cover: BlogCoverPalette | null;
  readonly draft: boolean;
}

/** Listedeki yazı: ön bilgi, kısa ad, durum ve dosyanın GitHub sürümü (`sha`; güncelleme ve silme bunu ister). */
export interface BlogPostSummary extends BlogFrontMatter {
  readonly slug: string;
  readonly status: BlogPostStatus;
  readonly sha: string;
}

/** Yazının tamamı: Markdown gövdesi de. */
export interface BlogPost extends BlogPostSummary {
  readonly body: string;
}

/** Kayıt sonucu: yeni dosya mı ve yazının kayıttan sonraki hâli. */
export interface SavedBlogPost {
  readonly created: boolean;
  readonly post: BlogPost;
}

/** Jetonu girilmiş blog yapılandırması (`requireBlog`). */
export interface ActiveBlog {
  readonly owner: string;
  readonly repo: string;
  readonly branch: string;
  readonly token: string;
}

/** Kısa ad: küçük harf, rakam ve tek tirelerle ayrılmış parçalar; en çok 80 karakter. */
export const blogSlugPattern: RegExp = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const blogSlugMaxLength: number = 80;
/** Gövdenin en çok karakter sayısı. */
export const blogBodyMaxLength: number = 60_000;
/** `PUT` isteğinin en büyük gövdesi (bayt): 60 000 karakterlik gövde UTF-8 ve JSON kaçışıyla birlikte sığar. */
export const blogRequestMaxBytes: number = 512 * 1024;

/** Tek satırlık alanlarda yasak: denetim karakterleri (C0, DEL, C1) ve eşi olmayan vekil karakterler. */
const lineForbidden: RegExp = /[\u0000-\u001f\u007f-\u009f\ud800-\udfff]/u;
/** Gövdede yasak: sekme ve satır sonu dışındaki denetim karakterleri, `\r` ve eşi olmayan vekil karakterler. */
const bodyForbidden: RegExp = /[\u0000-\u0008\u000b-\u001f\u007f\ud800-\udfff]/u;
const datePattern: RegExp = /^\d{4}-\d{2}-\d{2}$/;
const shaPattern: RegExp = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;

/** `YYYY-MM-DD` gerçek bir takvim günü mü. Saf fonksiyondur. */
function isCalendarDay(value: string): boolean {
  if (!datePattern.test(value)) {
    return false;
  }
  const parsed: Date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

/** Tek satırlık metin mi (denetim karakteri yok). Saf fonksiyondur. */
function isSingleLine(value: string): boolean {
  return !lineForbidden.test(value);
}

/** Ön bilgi alanları (içerik şemasıyla aynı kurallar). */
const frontMatterShape = {
  title: z.string().min(10).max(90).refine(isSingleLine, { message: "denetim karakteri" }),
  description: z.string().min(50).max(170).refine(isSingleLine, { message: "denetim karakteri" }),
  author: z.string().min(1).refine(isSingleLine, { message: "denetim karakteri" }),
  published: z.string().refine(isCalendarDay, { message: "YYYY-MM-DD olmalı" }),
  updated: z.string().refine(isCalendarDay, { message: "YYYY-MM-DD olmalı" }).nullable(),
  cover: z.enum(blogCoverPalettes).nullable(),
  draft: z.boolean(),
};

/** `updated` yazılmışsa `published`'dan önce olamaz. Saf fonksiyondur. */
function isUpdatedAfterPublished(value: { readonly published: string; readonly updated: string | null }): boolean {
  return value.updated === null || value.updated >= value.published;
}

const updatedRule = { message: "published'dan önce", path: ["updated"] };

const frontMatterSchema = z.strictObject(frontMatterShape).refine(isUpdatedAfterPublished, updatedRule);

/**
 * `PUT /v1/admin/blog/posts/{kısa ad}` gövdesi: `updated` ve `cover` her istekte açıkça yazılır (yoksa null); `sha` yeni
 * yazıda null, güncellemede panelin bildiği son sürüm.
 */
export const blogPostInputSchema = z
  .strictObject({
    ...frontMatterShape,
    body: z
      .string()
      .max(blogBodyMaxLength)
      .refine((value: string): boolean => value.trim().length > 0, { message: "boş" })
      .refine((value: string): boolean => !bodyForbidden.test(value), { message: "denetim karakteri" }),
    sha: z.string().regex(shaPattern).nullable(),
  })
  .refine(isUpdatedAfterPublished, updatedRule);

/** Kayıt isteği. */
export type BlogPostInput = z.output<typeof blogPostInputSchema>;

/** Yoldaki kısa adı doğrular; geçersizse `bad_request`. Saf fonksiyondur. */
export function parseBlogSlug(value: string): string {
  if (value.length > blogSlugMaxLength || !blogSlugPattern.test(value)) {
    throw new ApiError("bad_request", "Kısa ad küçük harf, rakam ve tirelerden oluşmalı (en çok 80 karakter).");
  }
  return value;
}

/** Silme isteğinin `?sha=` değeri; yoksa ya da biçimi yanlışsa `bad_request`. Saf fonksiyondur. */
export function parseBlogSha(url: URL): string {
  const sha: string | null = url.searchParams.get("sha");
  if (sha === null || !shaPattern.test(sha)) {
    throw new ApiError("bad_request", "sha sorgu değeri (dosyanın bilinen son sürümü) gerekli.");
  }
  return sha;
}

/** Jeton girilmişse etkin yapılandırma; girilmemişse `blog_unavailable`. Saf fonksiyondur. */
export function requireBlog(blog: BlogConfig): ActiveBlog {
  if (blog.token === null) {
    throw new ApiError("blog_unavailable", "Blog yayını kapalı: sunucuda GITHUB_BLOG_TOKEN girilmemiş.");
  }
  return { owner: blog.owner, repo: blog.repo, branch: blog.branch, token: blog.token };
}

/** Yazının durumu (`today`: UTC günü, `YYYY-MM-DD`). Saf fonksiyondur. */
export function blogPostStatus(draft: boolean, published: string, today: string): BlogPostStatus {
  if (draft) {
    return "draft";
  }
  return published > today ? "scheduled" : "live";
}

/** Gövdenin dosyadaki biçimi: baştaki boş satırlar ve sondaki boşluklar atılır. Saf fonksiyondur. */
export function normalizedBlogBody(body: string): string {
  return body.replace(/^\n+/, "").trimEnd();
}

/**
 * Yazının dosya içeriği: sabit sıralı ön bilgi (metinler JSON kaçışlı çift tırnak içinde: YAML 1.2'de geçerli ve
 * her değer için güvenli; tarihler, kapak ve taslak düz; `updated` ve `cover` yalnızca doluysa), boş satır, gövde ve tek
 * satır sonu. Saf fonksiyondur.
 */
export function serializeBlogPost(frontMatter: BlogFrontMatter, body: string): string {
  return [
    "---",
    `title: ${JSON.stringify(frontMatter.title)}`,
    `description: ${JSON.stringify(frontMatter.description)}`,
    `author: ${JSON.stringify(frontMatter.author)}`,
    `published: ${frontMatter.published}`,
    ...(frontMatter.updated === null ? [] : [`updated: ${frontMatter.updated}`]),
    ...(frontMatter.cover === null ? [] : [`cover: ${frontMatter.cover}`]),
    `draft: ${String(frontMatter.draft)}`,
    "---",
    "",
    normalizedBlogBody(body),
    "",
  ].join("\n");
}

/** Okunan dosyanın ön bilgisi ve gövdesi. */
export interface ParsedBlogFile {
  readonly frontMatter: BlogFrontMatter;
  readonly body: string;
}

/** YAML'ın metin dışı bir değere çevirdiği düz değerler (boş, mantıksal, sayı, tarih). */
const nonStringPlain: RegExp = /^(?:~|null|Null|NULL|true|True|TRUE|false|False|FALSE|[-+]?(?:\d[\d_]*)?\.?\d+(?:[eE][-+]?\d+)?|0x[0-9a-fA-F]+|0o[0-7]+|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN)|\d{4}-\d{2}-\d{2}(?:[Tt ].*)?)$/;

/**
 * Ön bilgideki bir değerin metni: çift tırnaklı (JSON kaçışlı), tek tırnaklı (`''` kaçışlı) ya da düz. Düz değer YAML
 * işaretiyle başlıyor, `: ` ya da ` #` içeriyorsa okunamaz: null. Saf fonksiyondur.
 */
function scalarText(raw: string): string | null {
  if (raw.startsWith('"')) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return null;
    }
    return typeof parsed === "string" ? parsed : null;
  }
  if (raw.startsWith("'")) {
    const inner: string = raw.slice(1, -1);
    const valid: boolean = raw.length >= 2 && raw.endsWith("'") && !inner.replaceAll("''", "").includes("'");
    return valid ? inner.replaceAll("''", "'") : null;
  }
  const plain: boolean =
    raw.length > 0 && !/^[[\]{}&*!|>%@`#,]/.test(raw) && !/^[?:-](?:\s|$)/.test(raw) && !raw.includes(": ") && !raw.includes(" #") && !raw.endsWith(":");
  return plain ? raw : null;
}

/** Ön bilgideki metin alanı: düz değer YAML'da metin olmalı (ör. `true` ya da `2026` değil). Saf fonksiyondur. */
function stringValue(raw: string): string | null {
  if (!raw.startsWith('"') && !raw.startsWith("'") && nonStringPlain.test(raw)) {
    return null;
  }
  return scalarText(raw);
}

/** Dosya okunamadı: kısa adı ve sorunu taşıyan `blog_post_invalid`. Saf fonksiyondur. */
function invalidFile(slug: string, problem: string): ApiError {
  return new ApiError("blog_post_invalid", `${blogDirectory}/${slug}.md okunamadı: ${problem}`);
}

/**
 * İsteğe bağlı alanın değeri: yazılmamışsa null. Yazılmış ama okunamıyorsa boş metin döner ki şema onu reddetsin
 * (geçersiz değer yok sayılıp sessizce silinmesin). Saf fonksiyondur.
 */
function optionalScalar(values: ReadonlyMap<string, string>, key: "updated" | "cover"): string | null {
  const raw: string | undefined = values.get(key);
  return raw === undefined ? null : (scalarText(raw) ?? "");
}

/**
 * Yazı dosyasını okur. Ön bilgi `---` satırlarıyla çevrili, satır başına `alan: değer` olmalı; yalnızca `title`,
 * `description`, `author`, `published`, `updated`, `cover`, `draft` alanları (her biri bir kez; `updated` ve `cover`
 * isteğe bağlı) kabul edilir: bilinmeyen alan kayıtta sessizce kaybolmasın diye reddedilir. Alanlar
 * `blogPostInputSchema` kurallarına uymalı, gövde boş olmamalı. Okunamayan dosya `blog_post_invalid`. Saf fonksiyondur.
 */
export function parseBlogFile(slug: string, text: string): ParsedBlogFile {
  if (!text.startsWith("---\n")) {
    throw invalidFile(slug, "ön bilgi `---` ile başlamıyor");
  }
  const end: number = text.indexOf("\n---\n", 3);
  if (end < 0) {
    throw invalidFile(slug, "ön bilginin kapanış `---` satırı yok");
  }
  const values: Map<string, string> = new Map();
  for (const line of text.slice(4, end + 1).split("\n")) {
    if (line.trim() === "") {
      continue;
    }
    const match: RegExpExecArray | null = /^([A-Za-z]+):(?: +(.*?))? *$/.exec(line);
    const key: string | undefined = match?.[1];
    if (key === undefined || !Object.hasOwn(frontMatterShape, key)) {
      throw invalidFile(slug, `desteklenmeyen ön bilgi satırı: ${line.slice(0, 60)}`);
    }
    if (values.has(key)) {
      throw invalidFile(slug, `${key} iki kez yazılmış`);
    }
    values.set(key, match?.[2] ?? "");
  }
  const raw = (key: keyof BlogFrontMatter): string => values.get(key) ?? "";
  const draftRaw: string = raw("draft");
  const candidate = {
    title: stringValue(raw("title")),
    description: stringValue(raw("description")),
    author: stringValue(raw("author")),
    published: scalarText(raw("published")),
    updated: optionalScalar(values, "updated"),
    cover: optionalScalar(values, "cover"),
    draft: draftRaw === "true" ? true : draftRaw === "false" ? false : null,
  };
  const parsed = frontMatterSchema.safeParse(candidate);
  if (!parsed.success) {
    const fields: string = [...new Set(parsed.error.issues.map((issue: z.core.$ZodIssue): string => issue.path.join(".")))].join(", ");
    throw invalidFile(slug, `geçersiz alanlar: ${fields}`);
  }
  const body: string = normalizedBlogBody(text.slice(end + 5));
  if (body === "") {
    throw invalidFile(slug, "gövde boş");
  }
  return { frontMatter: parsed.data, body };
}

/** GitHub REST ve GraphQL adresi. */
const githubApi: string = "https://api.github.com";
/** Yeniden deneme: 408, 429, 5xx, ağ hatası ve zaman aşımı uyarıyla 3 kez. */
const githubAttempts: number = 3;
const githubTimeoutMs: number = 10_000;

/** GitHub yanıtı: durum ve gövde metni. */
interface GithubReply {
  readonly status: number;
  readonly text: string;
}

/** GitHub'da yeniden denenebilir durum. 409 (contents API'de sürüm çakışması) ve 403 (yetki ya da ikincil hız sınırı) değil. Saf fonksiyondur. */
function isRetryableGithubStatus(status: number): boolean {
  return status === 408 || status === 429 || status >= 500;
}

/** Yazı dosyasının depodaki yolu. Saf fonksiyondur. */
function postPath(slug: string): string {
  return `${blogDirectory}/${slug}.md`;
}

/** Yazının görsel klasörünün depodaki yolu. Saf fonksiyondur. */
function imageFolderPath(slug: string): string {
  return `${blogImageDirectory}/${slug}`;
}

/** Depodaki dosyanın REST contents adresi. Saf fonksiyondur. */
function contentsUrl(blog: ActiveBlog, repoPath: string): string {
  return `${githubApi}/repos/${blog.owner}/${blog.repo}/contents/${repoPath}`;
}

/**
 * GitHub'a istek atar. 2xx, 404 ve 409 yanıt olarak döner (anlamlarına çağıran karar verir); diğer durumlarda GitHub'ın
 * hata gövdesi (jeton içermez) `github_request_failed` uyarısıyla loglanır ve `UpstreamError` fırlatılır. 408, 429,
 * 5xx, ağ hatası ve zaman aşımı uyarıyla `githubAttempts` kez denenir. Jeton loglanmaz.
 */
async function githubRequest(platform: Platform, blog: ActiveBlog, operation: string, method: string, url: string, body: object | null): Promise<GithubReply> {
  return withRetries(
    { service: "github", attempts: githubAttempts, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableUpstreamError, recordRetry: platform.recordRetry },
    async (): Promise<GithubReply> => {
      const headers: Record<string, string> = {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${blog.token}`,
        "user-agent": "gistsmith-admin-blog",
        "x-github-api-version": "2022-11-28",
      };
      if (body !== null) {
        headers["content-type"] = "application/json";
      }
      const response: Response = await platform.fetch(url, {
        method,
        headers,
        body: body === null ? null : JSON.stringify(body),
        signal: AbortSignal.timeout(githubTimeoutMs),
      });
      const text: string = await response.text();
      if (response.ok || response.status === 404 || response.status === 409) {
        return { status: response.status, text };
      }
      const reason: string = text.slice(0, 300);
      log("warn", "github_request_failed", { operation, method, status: response.status, reason });
      throw new UpstreamError("github", response.status, isRetryableGithubStatus(response.status), reason);
    },
  );
}

/**
 * `githubRequest`'in denemeleri bitince kalan hatayı istemci hatasına çevirir: GitHub'ın reddi (401, 403, 422…)
 * `upstream_rejected` (durumla), geçici hata, ağ hatası ve zaman aşımı `upstream_unavailable`.
 */
async function github(platform: Platform, blog: ActiveBlog, operation: string, method: string, url: string, body: object | null): Promise<GithubReply> {
  try {
    return await githubRequest(platform, blog, operation, method, url, body);
  } catch (error: unknown) {
    if (error instanceof UpstreamError) {
      throw error.retryable
        ? new ProviderApiError("github", "upstream_unavailable", `GitHub şu an yanıt vermiyor (durum ${error.status}); biraz sonra yeniden dene.`)
        : new ProviderApiError("github", "upstream_rejected", `GitHub isteği reddetti (durum ${error.status}); jetonun bu depoda Contents okuma ve yazma yetkisini denetle.`);
    }
    if (error instanceof TypeError || isTimeoutError(error)) {
      log("warn", "github_unreachable", { operation, method, error: errorName(error) });
      throw new ProviderApiError("github", "upstream_unavailable", "GitHub'a ulaşılamadı; biraz sonra yeniden dene.");
    }
    throw error;
  }
}

/** GitHub yanıtı beklenen biçimde değil: gövdenin başı uyarıyla loglanır, `upstream_unavailable`. */
function invalidGithubResponse(reply: GithubReply, operation: string, problem: string): ProviderApiError {
  log("warn", "github_response_invalid", { operation, status: reply.status, problem, body: reply.text.slice(0, 300) });
  return new ProviderApiError("github", "upstream_unavailable", "GitHub yanıtı beklenen biçimde değil.");
}

/** GitHub yanıtını JSON olarak şemayla okur; beklenen biçimde değilse `invalidGithubResponse`. */
function githubJson<Schema extends z.ZodType>(schema: Schema, reply: GithubReply, operation: string): z.output<Schema> {
  let raw: unknown;
  try {
    raw = JSON.parse(reply.text);
  } catch (error: unknown) {
    throw invalidGithubResponse(reply, operation, errorName(error));
  }
  const parsed = schema.safeParse(raw);
  if (!parsed.success) {
    throw invalidGithubResponse(reply, operation, parsed.error.issues.map((issue: z.core.$ZodIssue): string => issue.path.join(".")).join(","));
  }
  return parsed.data;
}

/** Beklenmeyen GitHub durumu (ör. kayıtta 404: depo ya da dal yok): uyarı loglanır, `upstream_rejected`. */
function unexpectedGithubStatus(reply: GithubReply, operation: string): ProviderApiError {
  log("warn", "github_request_failed", { operation, status: reply.status, reason: reply.text.slice(0, 300) });
  return new ProviderApiError("github", "upstream_rejected", `GitHub beklenmeyen bir yanıt verdi (durum ${reply.status}); GITHUB_BLOG_REPO ve GITHUB_BLOG_BRANCH'i denetle.`);
}

const contentsFileSchema = z.object({
  type: z.literal("file"),
  sha: z.string().regex(shaPattern),
  encoding: z.literal("base64"),
  content: z.string(),
});

const contentsWriteSchema = z.object({ content: z.object({ sha: z.string().regex(shaPattern) }) });

const treeQuery: string = `query BlogPosts($owner: String!, $name: String!, $expression: String!) {
  repository(owner: $owner, name: $name) {
    object(expression: $expression) {
      ... on Tree {
        entries { name type oid object { ... on Blob { text isTruncated } } }
      }
    }
  }
}`;

const treeSchema = z.object({
  data: z
    .object({
      repository: z
        .object({
          object: z
            .object({
              entries: z.array(
                z.object({
                  name: z.string(),
                  type: z.string(),
                  oid: z.string(),
                  object: z.object({ text: z.string().nullable().optional(), isTruncated: z.boolean().optional() }).nullable(),
                }),
              ),
            })
            .nullable(),
        })
        .nullable(),
    })
    .nullable()
    .optional(),
  errors: z.array(z.object({ type: z.string().optional(), message: z.string() })).optional(),
});

/** Depodaki dosya: GitHub sürümü ve metni. */
interface RepoFile {
  readonly sha: string;
  readonly text: string;
}

/** Yazı dosyasının içeriği; yoksa null. Bozuk base64 ya da UTF-8 `blog_post_invalid`. */
async function readFile(platform: Platform, blog: ActiveBlog, slug: string): Promise<RepoFile | null> {
  const reply: GithubReply = await github(platform, blog, "read", "GET", `${contentsUrl(blog, postPath(slug))}?ref=${encodeURIComponent(blog.branch)}`, null);
  if (reply.status === 404) {
    return null;
  }
  if (reply.status !== 200) {
    throw unexpectedGithubStatus(reply, "read");
  }
  const file = githubJson(contentsFileSchema, reply, "read");
  let text: string;
  try {
    text = decodeUtf8Strict(base64Decode(file.content.replace(/\s+/g, "")));
  } catch (error: unknown) {
    throw invalidFile(slug, `içerik çözülemedi (${errorName(error)})`);
  }
  return { sha: file.sha, text };
}

/** Listedeki yazının yanıt biçimi. Saf fonksiyondur. */
function blogSummaryOf(slug: string, sha: string, frontMatter: BlogFrontMatter, today: string): BlogPostSummary {
  return { slug, ...frontMatter, status: blogPostStatus(frontMatter.draft, frontMatter.published, today), sha };
}

/** Yazının yanıt biçimi (gövdesiyle). Saf fonksiyondur. */
function blogPostOf(slug: string, sha: string, parsed: ParsedBlogFile, today: string): BlogPost {
  return { ...blogSummaryOf(slug, sha, parsed.frontMatter, today), body: parsed.body };
}

/** Yazı sırası: yeniden eskiye, aynı gündekiler başlığa göre (sitenin blog dizini gibi). Saf fonksiyondur. */
export function compareBlogPosts(a: BlogFrontMatter, b: BlogFrontMatter): number {
  return b.published.localeCompare(a.published) || a.title.localeCompare(b.title);
}

/**
 * Tüm yazılar (gövdesiz), yeniden eskiye. Klasör yoksa (son yazı da silinmiş: git boş klasör tutmaz) liste boştur.
 * Klasördeki `.md` dışı dosyalar sitenin içerik koleksiyonu gibi yok sayılır; okunamayan bir yazı `blog_post_invalid`
 * (site de derlenemez). `today`: UTC günü.
 */
export async function listBlogPosts(platform: Platform, blog: ActiveBlog, today: string): Promise<BlogPostSummary[]> {
  const reply: GithubReply = await github(platform, blog, "list", "POST", `${githubApi}/graphql`, {
    query: treeQuery,
    variables: { owner: blog.owner, name: blog.repo, expression: `${blog.branch}:${blogDirectory}` },
  });
  if (reply.status !== 200) {
    throw unexpectedGithubStatus(reply, "list");
  }
  const tree = githubJson(treeSchema, reply, "list");
  if (tree.errors !== undefined && tree.errors.length > 0) {
    log("warn", "github_graphql_failed", { operation: "list", types: tree.errors.map((error): string => error.type ?? "unknown").join(","), reason: (tree.errors[0]?.message ?? "").slice(0, 200) });
    throw new ProviderApiError("github", "upstream_rejected", "GitHub yazı listesini vermedi; jetonun yetkisini ve GITHUB_BLOG_REPO'yu denetle.");
  }
  const repository = tree.data?.repository ?? null;
  if (repository === null) {
    throw unexpectedGithubStatus(reply, "list");
  }
  const entries = repository.object?.entries ?? [];
  return entries
    .filter((entry): boolean => entry.type === "blob" && entry.name.endsWith(".md"))
    .map((entry): BlogPostSummary => {
      const slug: string = entry.name.slice(0, -3);
      if (slug.length > blogSlugMaxLength || !blogSlugPattern.test(slug)) {
        throw invalidFile(slug, "dosya adı geçerli bir kısa ad değil");
      }
      const text: string | null | undefined = entry.object?.text;
      if (text === null || text === undefined || entry.object?.isTruncated === true) {
        throw invalidFile(slug, "metin okunamadı");
      }
      return blogSummaryOf(slug, entry.oid, parseBlogFile(slug, text).frontMatter, today);
    })
    .sort(compareBlogPosts);
}

/** Tek yazı; yoksa `not_found`. */
export async function getBlogPost(platform: Platform, blog: ActiveBlog, slug: string, today: string): Promise<BlogPost> {
  const file: RepoFile | null = await readFile(platform, blog, slug);
  if (file === null) {
    throw new ApiError("not_found", "Böyle bir yazı yok.");
  }
  return blogPostOf(slug, file.sha, parseBlogFile(slug, file.text), today);
}

/**
 * Yazıyı yaratır ya da günceller (dala `blog: <başlık>` commit'i). Yeni yazıda `sha` null olmalı: dosya varsa
 * `blog_post_exists`. Güncellemede `sha` panelin bildiği son sürüm olmalı: dosya silinmiş ya da başka sürüme geçmişse
 * (ya da GitHub yazım sırasında çakışma bildirirse) `blog_conflict`; hiçbir şey yazılmaz.
 */
export async function saveBlogPost(platform: Platform, blog: ActiveBlog, slug: string, input: BlogPostInput, today: string): Promise<SavedBlogPost> {
  const current: RepoFile | null = await readFile(platform, blog, slug);
  if (input.sha === null && current !== null) {
    throw new ApiError("blog_post_exists", "Bu kısa adla bir yazı zaten var.");
  }
  if (input.sha !== null && (current === null || current.sha !== input.sha)) {
    throw new ApiError("blog_conflict", "Yazı sen açtıktan sonra değişmiş ya da silinmiş; yeniden yükleyip dene.");
  }
  const frontMatter: BlogFrontMatter = {
    title: input.title,
    description: input.description,
    author: input.author,
    published: input.published,
    updated: input.updated,
    cover: input.cover,
    draft: input.draft,
  };
  const text: string = serializeBlogPost(frontMatter, input.body);
  const reply: GithubReply = await github(platform, blog, "write", "PUT", contentsUrl(blog, postPath(slug)), {
    message: `blog: ${input.title}`,
    content: base64Encode(utf8(text)),
    branch: blog.branch,
    ...(input.sha === null ? {} : { sha: input.sha }),
  });
  if (reply.status === 409) {
    throw new ApiError("blog_conflict", "Yazı sen açtıktan sonra değişmiş; yeniden yükleyip dene.");
  }
  if (reply.status !== 200 && reply.status !== 201) {
    throw unexpectedGithubStatus(reply, "write");
  }
  const written = githubJson(contentsWriteSchema, reply, "write");
  return { created: input.sha === null, post: blogPostOf(slug, written.content.sha, parseBlogFile(slug, text), today) };
}

/** Silinecek yazının dalın başındaki hâli: commit, yazının sürümü (yoksa null) ve görsel dosyalarının adları. */
interface DeletionState {
  readonly headOid: string;
  readonly postOid: string | null;
  readonly images: readonly string[];
}

const deletionQuery: string = `query BlogPostFiles($owner: String!, $name: String!, $ref: String!, $post: String!, $images: String!) {
  repository(owner: $owner, name: $name) {
    ref(qualifiedName: $ref) {
      target {
        ... on Commit {
          oid
          post: file(path: $post) { oid }
          images: file(path: $images) { type object { ... on Tree { entries { name type } } } }
        }
      }
    }
  }
}`;

const deletionStateSchema = z.object({
  data: z
    .object({
      repository: z
        .object({
          ref: z
            .object({
              target: z.object({
                oid: z.string().regex(shaPattern),
                post: z.object({ oid: z.string().regex(shaPattern) }).nullable(),
                images: z
                  .object({
                    type: z.string(),
                    object: z.object({ entries: z.array(z.object({ name: z.string(), type: z.string() })).optional() }).nullable(),
                  })
                  .nullable(),
              }),
            })
            .nullable(),
        })
        .nullable(),
    })
    .nullable()
    .optional(),
  errors: z.array(z.object({ type: z.string().optional(), message: z.string() })).optional(),
});

const createCommitMutation: string = `mutation DeleteBlogPost($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) { commit { oid } }
}`;

const createCommitSchema = z.object({
  data: z
    .object({ createCommitOnBranch: z.object({ commit: z.object({ oid: z.string() }) }).nullable() })
    .nullable()
    .optional(),
  errors: z.array(z.object({ type: z.string().optional(), message: z.string() })).optional(),
});

/** GraphQL hatası: türleri ve ilk mesajı uyarıyla loglanır, `upstream_rejected`. */
function graphqlRejected(operation: string, errors: ReadonlyArray<{ readonly type?: string | undefined; readonly message: string }>): ProviderApiError {
  log("warn", "github_graphql_failed", { operation, types: errors.map((error): string => error.type ?? "unknown").join(","), reason: (errors[0]?.message ?? "").slice(0, 200) });
  return new ProviderApiError("github", "upstream_rejected", "GitHub isteği reddetti; jetonun yetkisini ve GITHUB_BLOG_REPO'yu denetle.");
}

/**
 * Dalın başındaki commit, yazının sürümü ve görsel klasörünün dosyaları (tek GraphQL isteği, hepsi aynı commit'ten).
 * Klasörde dosya dışı öğe (alt klasör) varsa `blog_post_invalid`: panel yalnızca dosya yazar, elle temizlenmeli.
 */
async function readDeletionState(platform: Platform, blog: ActiveBlog, slug: string): Promise<DeletionState> {
  const reply: GithubReply = await github(platform, blog, "delete_read", "POST", `${githubApi}/graphql`, {
    query: deletionQuery,
    variables: { owner: blog.owner, name: blog.repo, ref: `refs/heads/${blog.branch}`, post: postPath(slug), images: imageFolderPath(slug) },
  });
  if (reply.status !== 200) {
    throw unexpectedGithubStatus(reply, "delete_read");
  }
  const state = githubJson(deletionStateSchema, reply, "delete_read");
  if (state.errors !== undefined && state.errors.length > 0) {
    throw graphqlRejected("delete_read", state.errors);
  }
  const target = state.data?.repository?.ref?.target ?? null;
  if (target === null) {
    throw unexpectedGithubStatus(reply, "delete_read");
  }
  const folder = target.images;
  if (folder !== null && folder.type !== "tree") {
    throw new ApiError("blog_post_invalid", `${imageFolderPath(slug)} bir klasör değil; depoda elle düzelt.`);
  }
  const entries: ReadonlyArray<{ readonly name: string; readonly type: string }> = folder?.object?.entries ?? [];
  const nested: string | undefined = entries.find((entry): boolean => entry.type !== "blob")?.name;
  if (nested !== undefined) {
    throw new ApiError("blog_post_invalid", `${imageFolderPath(slug)}/${nested} dosya değil; görsel klasöründe alt klasör olamaz, depoda elle temizle.`);
  }
  return { headOid: target.oid, postOid: target.post?.oid ?? null, images: entries.map((entry): string => entry.name) };
}

/** Commit başarısız: dal okunduktan sonra ilerledi (yeniden denenir) ya da GitHub reddetti. */
type CommitOutcome = "committed" | "stale";

/** GraphQL hatası dalın ilerlediğini mi söylüyor (`expectedHeadOid` tutmadı). Saf fonksiyondur. */
function isStaleHead(errors: ReadonlyArray<{ readonly type?: string | undefined; readonly message: string }>): boolean {
  return errors.some((error): boolean => error.type === "STALE_DATA" || error.message.includes("Expected branch to point to"));
}

/** Yazıyı ve görsellerini tek commit'te siler (`createCommitOnBranch`, beklenen dal başıyla). */
async function commitDeletion(platform: Platform, blog: ActiveBlog, slug: string, state: DeletionState): Promise<CommitOutcome> {
  const deletions: ReadonlyArray<{ readonly path: string }> = [
    { path: postPath(slug) },
    ...state.images.map((name: string): { readonly path: string } => ({ path: `${imageFolderPath(slug)}/${name}` })),
  ];
  const reply: GithubReply = await github(platform, blog, "delete", "POST", `${githubApi}/graphql`, {
    query: createCommitMutation,
    variables: {
      input: {
        branch: { repositoryNameWithOwner: `${blog.owner}/${blog.repo}`, branchName: blog.branch },
        expectedHeadOid: state.headOid,
        message: { headline: `blog: remove ${slug}` },
        fileChanges: { deletions },
      },
    },
  });
  if (reply.status !== 200) {
    throw unexpectedGithubStatus(reply, "delete");
  }
  const result = githubJson(createCommitSchema, reply, "delete");
  if (result.errors !== undefined && result.errors.length > 0) {
    if (isStaleHead(result.errors)) {
      return "stale";
    }
    throw graphqlRejected("delete", result.errors);
  }
  if (result.data?.createCommitOnBranch === null || result.data?.createCommitOnBranch === undefined) {
    throw invalidGithubResponse(reply, "delete", "createCommitOnBranch boş");
  }
  return "committed";
}

/** Dal arada başka bir commit'le ilerlerse silme yeniden okunup en çok bu kadar denenir. */
const deletionAttempts: number = 3;

/**
 * Yazıyı ve görsel klasörünü (`web/public/blog/<kısa ad>/`) tek commit'te siler (`blog: remove <kısa ad>`; GraphQL
 * `createCommitOnBranch`, dal başı beklenen commit olmalı). Yazı yoksa `not_found`, sürüm `sha` değilse `blog_conflict`.
 * Dal okunduktan sonra başka bir commit'le ilerlerse (yazı aynı kaldıkça) uyarıyla yeniden okunup denenir; denemeler
 * biterse `blog_conflict`.
 */
export async function deleteBlogPost(platform: Platform, blog: ActiveBlog, slug: string, sha: string): Promise<number> {
  for (let attempt: number = 1; attempt <= deletionAttempts; attempt += 1) {
    const state: DeletionState = await readDeletionState(platform, blog, slug);
    if (state.postOid === null) {
      throw new ApiError("not_found", "Böyle bir yazı yok.");
    }
    if (state.postOid !== sha) {
      throw new ApiError("blog_conflict", "Yazı sen açtıktan sonra değişmiş; yeniden yükleyip dene.");
    }
    if ((await commitDeletion(platform, blog, slug, state)) === "committed") {
      return state.images.length;
    }
    log("warn", "blog_delete_stale_head", { slug, attempt });
  }
  throw new ApiError("blog_conflict", "Depo silme sırasında sürekli değişti; biraz sonra yeniden dene.");
}

/** Görsel adı: küçük harf, rakam ve tire, `.webp` uzantılı; en çok 80 karakter (yazının klasöründe). */
export const blogImageNamePattern: RegExp = /^[a-z0-9-]+\.webp$/;
const blogImageNameMaxLength: number = 80;
/** Görselin en büyük boyu (bayt, çözülmüş): panel tarayıcıda küçültüp WebP'ye çevirir, büyükse yüklemez. */
export const blogImageMaxBytes: number = 600 * 1024;
/** Görselin en büyük genişliği (piksel): panel bu genişliğe küçültür. */
export const blogImageMaxWidth: number = 1600;
/** `PUT` isteğinin en büyük gövdesi (bayt): en büyük görselin base64'ü ve JSON sarmalı sığar. */
export const blogImageRequestMaxBytes: number = Math.ceil(blogImageMaxBytes / 3) * 4 + 1024;

/** `PUT /v1/admin/blog/posts/{kısa ad}/images/{ad}` gövdesi: görselin standart base64'ü (dolgulu, satır sonsuz). */
export const blogImageInputSchema = z.strictObject({
  data: z.string().min(4).regex(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/),
});

/** Yüklenen görsel: sitedeki yolu, GitHub sürümü ve boyutu. */
export interface SavedBlogImage {
  readonly path: string;
  readonly sha: string;
  readonly bytes: number;
  readonly width: number;
  readonly height: number;
}

/** Yoldaki görsel adını doğrular; geçersizse `bad_request`. Saf fonksiyondur. */
export function parseBlogImageName(value: string): string {
  if (value.length > blogImageNameMaxLength || !blogImageNamePattern.test(value)) {
    throw new ApiError("bad_request", "Görsel adı küçük harf, rakam ve tirelerden oluşmalı ve .webp ile bitmeli (en çok 80 karakter).");
  }
  return value;
}

/** Görselin piksel boyutu. */
export interface ImageDimensions {
  readonly width: number;
  readonly height: number;
}

/** Doğrulanmış görsel: baytları ve boyutu. */
export interface DecodedBlogImage {
  readonly bytes: Uint8Array;
  readonly dimensions: ImageDimensions;
}

/** Dört baytlık ASCII etiket mi. Saf fonksiyondur. */
function hasTag(bytes: Uint8Array, offset: number, tag: string): boolean {
  return [...tag].every((char: string, index: number): boolean => bytes[offset + index] === char.charCodeAt(0));
}

/** Küçük sonlu (little-endian) işaretsiz tamsayı. Saf fonksiyondur. */
function littleEndian(bytes: Uint8Array, offset: number, length: number): number {
  let value: number = 0;
  for (let index: number = length - 1; index >= 0; index -= 1) {
    value = value * 256 + (bytes[offset + index] ?? 0);
  }
  return value;
}

/**
 * WebP'nin boyutu: RIFF/WEBP imzası, RIFF boyunun dosyayla tutması ve ilk parça (`VP8 `, `VP8L`, `VP8X`). WebP değilse
 * `unsupported_media_type`. Sitenin derlemesi aynı kurallarla okur (`web/src/lib/blog-images.ts` `webpSize`). Saf
 * fonksiyondur.
 */
export function webpDimensions(bytes: Uint8Array): ImageDimensions {
  if (bytes.length < 30 || !hasTag(bytes, 0, "RIFF") || !hasTag(bytes, 8, "WEBP") || littleEndian(bytes, 4, 4) + 8 !== bytes.length) {
    throw new ApiError("unsupported_media_type", "Görsel WebP değil (RIFF/WEBP imzası yok ya da dosya eksik).");
  }
  if (hasTag(bytes, 12, "VP8 ")) {
    return { width: littleEndian(bytes, 26, 2) & 0x3fff, height: littleEndian(bytes, 28, 2) & 0x3fff };
  }
  if (hasTag(bytes, 12, "VP8L")) {
    const bits: number = littleEndian(bytes, 21, 4);
    return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  if (hasTag(bytes, 12, "VP8X")) {
    return { width: littleEndian(bytes, 24, 3) + 1, height: littleEndian(bytes, 27, 3) + 1 };
  }
  throw new ApiError("unsupported_media_type", "Görsel WebP değil (ilk parça VP8, VP8L ya da VP8X değil).");
}

/**
 * Gövdedeki base64'ü çözer ve görseli doğrular: en çok `blogImageMaxBytes` (`payload_too_large`), WebP
 * (`unsupported_media_type`), genişlik en çok `blogImageMaxWidth` ve boyutlar sıfır değil (`invalid_body`). Saf
 * fonksiyondur.
 */
export function decodeBlogImage(data: string): DecodedBlogImage {
  const bytes: Uint8Array = base64Decode(data);
  if (bytes.length > blogImageMaxBytes) {
    throw new ApiError("payload_too_large", `Görsel en çok ${blogImageMaxBytes} bayt olabilir (gelen ${bytes.length}).`);
  }
  const dimensions: ImageDimensions = webpDimensions(bytes);
  if (dimensions.width === 0 || dimensions.height === 0 || dimensions.width > blogImageMaxWidth) {
    throw new ApiError("invalid_body", `Görsel en çok ${blogImageMaxWidth} piksel genişlikte olmalı (gelen ${dimensions.width}×${dimensions.height}).`);
  }
  return { bytes, dimensions };
}

/**
 * Görseli yazının klasörüne yazar (dala `blog: image <kısa ad>/<ad>` commit'i; GitHub contents API). Yazı yoksa
 * `not_found` (önce yazı kaydedilir: klasör yazıyla birlikte silinsin diye kısa ad sabit olmalı); aynı adda görsel
 * varsa `blog_image_exists` (görseller değiştirilmez, yeni adla yüklenir); GitHub yazım sırasında çakışma bildirirse
 * `blog_conflict`.
 */
export async function saveBlogImage(platform: Platform, blog: ActiveBlog, slug: string, name: string, image: DecodedBlogImage): Promise<SavedBlogImage> {
  if ((await readFile(platform, blog, slug)) === null) {
    throw new ApiError("not_found", "Böyle bir yazı yok; görsel eklemeden önce yazıyı kaydet.");
  }
  const repoPath: string = `${imageFolderPath(slug)}/${name}`;
  const existing: GithubReply = await github(platform, blog, "image_read", "GET", `${contentsUrl(blog, repoPath)}?ref=${encodeURIComponent(blog.branch)}`, null);
  if (existing.status === 200) {
    throw new ApiError("blog_image_exists", "Bu yazıda bu adla bir görsel zaten var; başka bir ad seç.");
  }
  if (existing.status !== 404) {
    throw unexpectedGithubStatus(existing, "image_read");
  }
  const reply: GithubReply = await github(platform, blog, "image_write", "PUT", contentsUrl(blog, repoPath), {
    message: `blog: image ${slug}/${name}`,
    content: base64Encode(image.bytes),
    branch: blog.branch,
  });
  if (reply.status === 409) {
    throw new ApiError("blog_conflict", "Depo yükleme sırasında değişti; yeniden dene.");
  }
  if (reply.status !== 201) {
    throw unexpectedGithubStatus(reply, "image_write");
  }
  const written = githubJson(contentsWriteSchema, reply, "image_write");
  return { path: `/blog/${slug}/${name}`, sha: written.content.sha, bytes: image.bytes.length, width: image.dimensions.width, height: image.dimensions.height };
}

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
 * Alan kuralları içerik şemasıyla aynıdır (başlık 10–90, açıklama 50–170, yazar boş değil, tarih `YYYY-MM-DD`, taslak
 * mantıksal); ayrıca tek satırlık alanlarda denetim karakteri olamaz (ön bilgi YAML'ı güvenle yazılsın diye).
 */

/** Yazıların depodaki klasörü. */
export const blogDirectory: string = "web/src/content/blog";

/** Yazının durumu: taslak, tarihi gelecekte (zamanlanmış) ya da yayında (tarihi bugün ya da geçmişte, UTC). */
export type BlogPostStatus = "draft" | "scheduled" | "live";

/** Yazının ön bilgisi (`published`: `YYYY-MM-DD`). */
export interface BlogFrontMatter {
  readonly title: string;
  readonly description: string;
  readonly author: string;
  readonly published: string;
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
  draft: z.boolean(),
};

const frontMatterSchema = z.strictObject(frontMatterShape);

/** `PUT /v1/admin/blog/posts/{kısa ad}` gövdesi: `sha` yeni yazıda null, güncellemede panelin bildiği son sürüm. */
export const blogPostInputSchema = z.strictObject({
  ...frontMatterShape,
  body: z
    .string()
    .max(blogBodyMaxLength)
    .refine((value: string): boolean => value.trim().length > 0, { message: "boş" })
    .refine((value: string): boolean => !bodyForbidden.test(value), { message: "denetim karakteri" }),
  sha: z.string().regex(shaPattern).nullable(),
});

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
 * her değer için güvenli; tarih ve taslak düz), boş satır, gövde ve tek satır sonu. Saf fonksiyondur.
 */
export function serializeBlogPost(frontMatter: BlogFrontMatter, body: string): string {
  return [
    "---",
    `title: ${JSON.stringify(frontMatter.title)}`,
    `description: ${JSON.stringify(frontMatter.description)}`,
    `author: ${JSON.stringify(frontMatter.author)}`,
    `published: ${frontMatter.published}`,
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
 * Yazı dosyasını okur. Ön bilgi `---` satırlarıyla çevrili, satır başına `alan: değer` olmalı; yalnızca `title`,
 * `description`, `author`, `published`, `draft` alanları (her biri bir kez) kabul edilir: bilinmeyen alan kayıtta
 * sessizce kaybolmasın diye reddedilir. Alanlar `blogPostInputSchema` kurallarına uymalı, gövde boş olmamalı. Okunamayan
 * dosya `blog_post_invalid`. Saf fonksiyondur.
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

/** Dosyanın REST contents adresi. Saf fonksiyondur. */
function contentsUrl(blog: ActiveBlog, slug: string): string {
  return `${githubApi}/repos/${blog.owner}/${blog.repo}/contents/${blogDirectory}/${slug}.md`;
}

/**
 * GitHub'a istek atar. 2xx, 404 ve 409 yanıt olarak döner (anlamlarına çağıran karar verir); diğer durumlarda GitHub'ın
 * hata gövdesi (jeton içermez) `github_request_failed` uyarısıyla loglanır ve `UpstreamError` fırlatılır. 408, 429,
 * 5xx, ağ hatası ve zaman aşımı uyarıyla `githubAttempts` kez denenir. Jeton loglanmaz.
 */
async function githubRequest(platform: Platform, blog: ActiveBlog, operation: string, method: string, url: string, body: object | null): Promise<GithubReply> {
  return withRetries(
    { service: "github", attempts: githubAttempts, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableUpstreamError },
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

/** Dosyanın içeriği; yoksa null. Bozuk base64 ya da UTF-8 `blog_post_invalid`. */
async function readFile(platform: Platform, blog: ActiveBlog, slug: string): Promise<RepoFile | null> {
  const reply: GithubReply = await github(platform, blog, "read", "GET", `${contentsUrl(blog, slug)}?ref=${encodeURIComponent(blog.branch)}`, null);
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
  const frontMatter: BlogFrontMatter = { title: input.title, description: input.description, author: input.author, published: input.published, draft: input.draft };
  const text: string = serializeBlogPost(frontMatter, input.body);
  const reply: GithubReply = await github(platform, blog, "write", "PUT", contentsUrl(blog, slug), {
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

/** Yazıyı siler (dala `blog: remove <kısa ad>` commit'i). Dosya yoksa `not_found`, sürüm uyuşmazsa `blog_conflict`. */
export async function deleteBlogPost(platform: Platform, blog: ActiveBlog, slug: string, sha: string): Promise<void> {
  const reply: GithubReply = await github(platform, blog, "delete", "DELETE", contentsUrl(blog, slug), {
    message: `blog: remove ${slug}`,
    sha,
    branch: blog.branch,
  });
  if (reply.status === 404) {
    throw new ApiError("not_found", "Böyle bir yazı yok.");
  }
  if (reply.status === 409) {
    throw new ApiError("blog_conflict", "Yazı sen açtıktan sonra değişmiş; yeniden yükleyip dene.");
  }
  if (reply.status !== 200) {
    throw unexpectedGithubStatus(reply, "delete");
  }
}

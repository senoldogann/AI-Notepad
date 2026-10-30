import { describe, expect, it, vi } from "vitest";
import { filmPalettes } from "../../web/src/lib/film";
import realPostNoBot from "../../web/src/content/blog/meeting-notes-on-mac-without-a-bot.md?raw";
import realPostRecording from "../../web/src/content/blog/record-teams-zoom-google-meet-on-mac.md?raw";
import realPostTasks from "../../web/src/content/blog/turn-a-meeting-into-a-task-list.md?raw";
import { blogCoverPalettes, blogImageMaxBytes, parseBlogFile, serializeBlogPost, webpDimensions } from "../src/blog";
import { base64Encode, hexEncode, randomId, utf8 } from "../src/crypto";
import type { Env } from "../src/env";
import { type Harness, type Session, defaultHarness, envWith, expectError, req, signIn, signInWithGoogle } from "./helpers";

const token: string = "github_pat_test_0123456789abcdefghij";
const contentsRoot: string = "https://api.github.com/repos/senoldogann/AI-Notepad/contents/";
const contentsPrefix: string = `${contentsRoot}web/src/content/blog/`;
const imagesPrefix: string = `${contentsRoot}web/public/blog/`;

/** Sahte depodaki dosya. */
interface FakeFile {
  sha: string;
  text: string;
}

/** Sahte depodaki görsel. */
interface FakeImage {
  readonly sha: string;
  readonly bytes: Uint8Array;
}

/** Sahte GitHub'ın commit kaydı. */
interface FakeCommit {
  readonly message: string;
  readonly branch: string;
  readonly method: string;
  /** GraphQL commit'inde silinen yollar (contents API'de boş). */
  readonly deletions: readonly string[];
}

/**
 * Sahte GitHub: kısa ad → yazı, `kısa ad/ad` → görsel, dal başı (her commit'te ilerler), commit'ler. `staleOnce`
 * doluysa bir sonraki `createCommitOnBranch` dal başının arada ilerlediğini bildirir.
 */
interface FakeGithub {
  readonly files: Map<string, FakeFile>;
  readonly images: Map<string, FakeImage>;
  readonly commits: FakeCommit[];
  readonly extra: Map<string, string>;
  readonly head: { oid: string; staleOnce: boolean };
}

/** Metnin SHA-1'i (git sürümü yerine; yalnızca biçimi aynı: 40 onaltılık). */
async function sha1(text: string): Promise<string> {
  return hexEncode(new Uint8Array(await crypto.subtle.digest("SHA-1", utf8(text))));
}

/** GitHub'ın base64 biçimi: 60 karakterde bir satır sonu. */
function githubBase64(text: string): string {
  return (base64Encode(utf8(text)).match(/.{1,60}/g) ?? []).join("\n");
}

/** Dal başını ilerletir (yeni commit). */
async function advanceHead(fake: FakeGithub, message: string): Promise<void> {
  fake.head.oid = await sha1(`${fake.head.oid}\n${message}\n${fake.commits.length}`);
}

/** GraphQL isteğini karşılar: yazı listesi, silme öncesi okuma ve `createCommitOnBranch`. */
async function graphql(fake: FakeGithub, request: Request): Promise<Response> {
  const body: { query: string; variables: Record<string, unknown> } = await request.json();
  if (body.query.includes("query BlogPosts")) {
    expect(body.variables).toEqual({ owner: "senoldogann", name: "AI-Notepad", expression: "main:web/src/content/blog" });
    const entries = [
      ...[...fake.files.entries()].map(([slug, file]: [string, FakeFile]) => ({ name: `${slug}.md`, type: "blob", oid: file.sha, object: { text: file.text, isTruncated: false } })),
      ...[...fake.extra.entries()].map(([name, text]: [string, string]) => ({ name, type: "blob", oid: "e".repeat(40), object: { text, isTruncated: false } })),
    ];
    return Response.json({ data: { repository: { object: entries.length === 0 ? null : { entries } } } });
  }
  if (body.query.includes("query BlogPostFiles")) {
    const variables = body.variables as { owner: string; name: string; ref: string; post: string; images: string };
    expect(variables.ref).toBe("refs/heads/main");
    const slug: string = variables.post.replace("web/src/content/blog/", "").replace(/\.md$/, "");
    expect(variables.images).toBe(`web/public/blog/${slug}`);
    const post: FakeFile | undefined = fake.files.get(slug);
    const names: string[] = [...fake.images.keys()].filter((key: string): boolean => key.startsWith(`${slug}/`)).map((key: string): string => key.slice(slug.length + 1));
    return Response.json({
      data: {
        repository: {
          ref: {
            target: {
              oid: fake.head.oid,
              post: post === undefined ? null : { oid: post.sha },
              images: names.length === 0 ? null : { type: "tree", object: { entries: names.map((name: string) => ({ name, type: "blob" })) } },
            },
          },
        },
      },
    });
  }
  if (body.query.includes("createCommitOnBranch")) {
    const input = (body.variables as { input: { branch: { repositoryNameWithOwner: string; branchName: string }; expectedHeadOid: string; message: { headline: string }; fileChanges: { deletions: Array<{ path: string }> } } }).input;
    expect(input.branch.repositoryNameWithOwner).toBe("senoldogann/AI-Notepad");
    if (fake.head.staleOnce || input.expectedHeadOid !== fake.head.oid) {
      fake.head.staleOnce = false;
      await advanceHead(fake, "someone else");
      return Response.json({ data: { createCommitOnBranch: null }, errors: [{ type: "STALE_DATA", message: `Expected branch to point to "${input.expectedHeadOid}" but it did not. Pull and try again.` }] });
    }
    const deletions: string[] = input.fileChanges.deletions.map((deletion): string => deletion.path);
    for (const path of deletions) {
      if (path.startsWith("web/src/content/blog/")) {
        fake.files.delete(path.replace("web/src/content/blog/", "").replace(/\.md$/, ""));
      } else {
        fake.images.delete(path.replace("web/public/blog/", ""));
      }
    }
    fake.commits.push({ message: input.message.headline, branch: input.branch.branchName, method: "GRAPHQL", deletions });
    await advanceHead(fake, input.message.headline);
    return Response.json({ data: { createCommitOnBranch: { commit: { oid: fake.head.oid } } } });
  }
  return Response.json({ errors: [{ message: "unknown query" }] });
}

/** Görsel dosyalarının REST contents sahtesi (okuma ve yaratma). */
async function imageContents(fake: FakeGithub, request: Request): Promise<Response> {
  const key: string = decodeURIComponent(request.url.slice(imagesPrefix.length).split("?")[0] ?? "");
  const current: FakeImage | undefined = fake.images.get(key);
  if (request.method === "GET") {
    return current === undefined
      ? Response.json({ message: "Not Found" }, { status: 404 })
      : Response.json({ type: "file", sha: current.sha, encoding: "base64", content: base64Encode(current.bytes) });
  }
  const body: { message: string; content: string; branch: string; sha?: string } = await request.json();
  if (current !== undefined) {
    return Response.json({ message: "Invalid request.\n\n\"sha\" wasn't supplied." }, { status: 422 });
  }
  const bytes: Uint8Array = Uint8Array.from(atob(body.content), (char: string): number => char.charCodeAt(0));
  const sha: string = await sha1(`${key}\n${body.content}`);
  fake.images.set(key, { sha, bytes });
  fake.commits.push({ message: body.message, branch: body.branch, method: "PUT", deletions: [] });
  await advanceHead(fake, body.message);
  return Response.json({ content: { sha, name: key.split("/").at(-1) }, commit: { sha: fake.head.oid } }, { status: 201 });
}

/** GitHub REST contents ve GraphQL'in sahtesi; jeton ve kullanıcı aracısı her istekte denetlenir. */
function stubGithub(harness: Harness): FakeGithub {
  const fake: FakeGithub = { files: new Map(), images: new Map(), commits: [], extra: new Map(), head: { oid: "0".repeat(40), staleOnce: false } };
  harness.stub("https://api.github.com/", async (request: Request): Promise<Response> => {
    if (request.headers.get("authorization") !== `Bearer ${token}` || request.headers.get("user-agent") === null) {
      return Response.json({ message: "Bad credentials" }, { status: 401 });
    }
    const url: URL = new URL(request.url);
    if (url.pathname === "/graphql") {
      return graphql(fake, request);
    }
    if (request.method === "GET") {
      expect(url.searchParams.get("ref")).toBe("main");
    }
    if (request.url.startsWith(imagesPrefix)) {
      return imageContents(fake, request);
    }
    const slug: string = decodeURIComponent(request.url.slice(contentsPrefix.length).split("?")[0] ?? "").replace(/\.md$/, "");
    const current: FakeFile | undefined = fake.files.get(slug);
    if (request.method === "GET") {
      return current === undefined
        ? Response.json({ message: "Not Found" }, { status: 404 })
        : Response.json({ type: "file", sha: current.sha, encoding: "base64", content: githubBase64(current.text) });
    }
    const body: { message: string; content?: string; sha?: string; branch: string } = await request.json();
    if (request.method === "PUT") {
      if (current !== undefined && body.sha === undefined) {
        return Response.json({ message: "Invalid request.\n\n\"sha\" wasn't supplied." }, { status: 422 });
      }
      if (body.sha !== undefined && current?.sha !== body.sha) {
        return Response.json({ message: "conflict" }, { status: 409 });
      }
      const text: string = new TextDecoder().decode(Uint8Array.from(atob(body.content ?? ""), (char: string): number => char.charCodeAt(0)));
      const sha: string = await sha1(`${slug}\n${text}`);
      fake.files.set(slug, { sha, text });
      fake.commits.push({ message: body.message, branch: body.branch, method: "PUT", deletions: [] });
      await advanceHead(fake, body.message);
      return Response.json({ content: { sha, name: `${slug}.md` }, commit: { sha: "c".repeat(40) } }, { status: current === undefined ? 201 : 200 });
    }
    return Response.json({ message: "Not Found" }, { status: 404 });
  });
  return fake;
}

/** Yazı dosyası (deponun biçiminde). */
function postFile(title: string, published: string, draft: boolean): string {
  return `---\ntitle: ${title}\ndescription: A description that is long enough for the content schema to accept it here.\nauthor: Senol Dogan\npublished: ${published}\ndraft: ${String(draft)}\n---\n\nFirst paragraph.\n\n## Heading\n\nMore text.\n`;
}

/** Geçerli bir kayıt gövdesi. */
function input(fields: Partial<Record<string, string | boolean | null>>): object {
  return {
    title: "Weekly notes: what we shipped",
    description: 'A "quoted" summary: colons, # hashes and quotes stay safe inside the front matter.',
    author: "Senol Dogan",
    published: "2026-10-22",
    updated: null,
    cover: null,
    draft: false,
    body: "Intro paragraph.\n\n## Section\n\n- one\n- two\n",
    sha: null,
    ...fields,
  };
}

/**
 * Sahte WebP: RIFF/WEBP imzası, VP8L parçası ve verilen boyut (yalnızca başlık geçerlidir; sunucu görseli çözmez).
 * `length` toplam bayt sayısıdır.
 */
function fakeWebp(width: number, height: number, length: number): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(length);
  const view: DataView = new DataView(bytes.buffer);
  bytes.set(utf8("RIFF"), 0);
  view.setUint32(4, length - 8, true);
  bytes.set(utf8("WEBPVP8L"), 8);
  view.setUint32(16, length - 20, true);
  bytes[20] = 0x2f;
  view.setUint32(21, (width - 1) | ((height - 1) << 14), true);
  return bytes;
}

/** Görsel yükleme gövdesi. */
function imageBody(bytes: Uint8Array): object {
  return { data: base64Encode(bytes) };
}

interface PostBody {
  readonly slug: string;
  readonly title: string;
  readonly description: string;
  readonly author: string;
  readonly published: string;
  readonly updated: string | null;
  readonly cover: string | null;
  readonly draft: boolean;
  readonly status: string;
  readonly sha: string;
  readonly body: string;
}

interface ListBody {
  readonly today: string;
  readonly posts: ReadonlyArray<Omit<PostBody, "body">>;
}

interface ImageBody {
  readonly path: string;
  readonly sha: string;
  readonly bytes: number;
  readonly width: number;
  readonly height: number;
}

/** Testin düzeneği: sahte GitHub, testin kendi yöneticisi (kullanıcı başına hız sınırı testler arasında birikmesin) ve ortamı. */
interface Setup {
  readonly harness: Harness;
  readonly admin: Session;
  readonly fake: FakeGithub;
  /** Yöneticinin ve jetonun girildiği ortam. */
  readonly env: Env;
  /** Aynı yönetici, jetonsuz ortam. */
  readonly noTokenEnv: Env;
}

async function setup(): Promise<Setup> {
  const harness: Harness = await defaultHarness();
  const fake: FakeGithub = stubGithub(harness);
  const subject: string = `blog-admin-${randomId()}`;
  const admin: Session = await signInWithGoogle(harness, subject);
  return {
    harness,
    admin,
    fake,
    env: envWith({ ADMIN_IDENTITIES: `google:${subject}`, GITHUB_BLOG_TOKEN: token }),
    noTokenEnv: envWith({ ADMIN_IDENTITIES: `google:${subject}` }),
  };
}

function call(context: Setup, session: Session, method: string, path: string, json: object | null): Promise<Response> {
  return context.harness.call(req(method, path, { token: session.accessToken, env: context.env, json }));
}

/** Dışarıya giden GitHub istekleri. */
function githubRequests(harness: Harness): Request[] {
  return harness.outbound.filter((request: Request): boolean => request.url.startsWith("https://api.github.com/"));
}

describe("blog yazılarının dosya biçimi", () => {
  it("sitedeki gerçek yazılar okunur", () => {
    for (const [slug, text] of [
      ["meeting-notes-on-mac-without-a-bot", realPostNoBot],
      ["record-teams-zoom-google-meet-on-mac", realPostRecording],
      ["turn-a-meeting-into-a-task-list", realPostTasks],
    ] as const) {
      const parsed = parseBlogFile(slug, text);
      expect(parsed.frontMatter.draft).toBe(false);
      expect(parsed.frontMatter.published).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(parsed.body.length).toBeGreaterThan(500);
    }
  });

  it("yazılan ön bilgi okunduğunda aynı değerleri verir (tırnak, iki nokta, diyez, ters bölü, Unicode)", () => {
    const frontMatter = { title: 'Say "hi": #1 \\ tips — ok', description: "x".repeat(60), author: "Şenol Doğan", published: "2026-11-05", updated: null, cover: null, draft: true };
    const text: string = serializeBlogPost(frontMatter, "\n\nBody line\n\n");
    expect(text.startsWith('---\ntitle: "Say \\"hi\\": #1 \\\\ tips — ok"\n')).toBe(true);
    expect(text).not.toContain("updated:");
    expect(text).not.toContain("cover:");
    expect(parseBlogFile("x", text)).toEqual({ frontMatter, body: "Body line" });
  });

  it("isteğe bağlı updated ve cover yazılır ve okunur; geçersiz değer, boş alan ya da yayından önceki updated reddedilir", () => {
    const frontMatter = { title: "A post with a cover", description: "y".repeat(60), author: "Senol Dogan", published: "2026-10-01", updated: "2026-10-12", cover: "ocean" as const, draft: false };
    const text: string = serializeBlogPost(frontMatter, "Body");
    expect(text).toContain("\npublished: 2026-10-01\nupdated: 2026-10-12\ncover: ocean\ndraft: false\n");
    expect(parseBlogFile("x", text)).toEqual({ frontMatter, body: "Body" });
    for (const broken of [
      text.replace("cover: ocean", "cover: teal"),
      text.replace("cover: ocean", "cover:"),
      text.replace("updated: 2026-10-12", "updated: 2026-09-30"),
      text.replace("updated: 2026-10-12", "updated: 12 Oct 2026"),
    ]) {
      expect(() => parseBlogFile("x", broken)).toThrow(/geçersiz alanlar/);
    }
  });

  it("kapak aileleri sitenin film aileleriyle aynıdır", () => {
    expect([...blogCoverPalettes]).toEqual([...filmPalettes]);
  });

  it("WebP boyutu VP8L, VP8 ve VP8X başlıklarından okunur; WebP olmayan ya da eksik dosya 415", () => {
    expect(webpDimensions(fakeWebp(1600, 900, 64))).toEqual({ width: 1600, height: 900 });
    const lossy: Uint8Array = fakeWebp(1, 1, 64);
    lossy.set(utf8("VP8 "), 12);
    new DataView(lossy.buffer).setUint16(26, 1200, true);
    new DataView(lossy.buffer).setUint16(28, 630, true);
    expect(webpDimensions(lossy)).toEqual({ width: 1200, height: 630 });
    const extended: Uint8Array = fakeWebp(1, 1, 64);
    extended.set(utf8("VP8X"), 12);
    extended.set([0x3f, 0x06, 0x00, 0x83, 0x03, 0x00], 24);
    expect(webpDimensions(extended)).toEqual({ width: 1600, height: 900 });
    for (const broken of [utf8("\u0089PNG\r\n\u001a\n".padEnd(64, "x")), fakeWebp(10, 10, 64).slice(0, 40)]) {
      expect(() => webpDimensions(broken)).toThrow(expect.objectContaining({ code: "unsupported_media_type" }));
    }
  });
});

describe("/v1/admin/blog", () => {
  it("liste: yazılar yeniden eskiye, durum (taslak, zamanlanmış, yayında) ve sürümle; .md dışı dosyalar yok sayılır", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    fake.files.set("older-post", { sha: "a".repeat(40), text: postFile("An older live post", "2026-10-01", false) });
    fake.files.set("today-post", { sha: "b".repeat(40), text: postFile("A post going live today", "2026-10-15", false) });
    fake.files.set("next-week", { sha: "c".repeat(40), text: postFile("A post scheduled for later", "2026-10-22", false) });
    fake.files.set("draft-post", { sha: "d".repeat(40), text: postFile("A draft dated in the past", "2026-10-02", true) });
    fake.extra.set("README.txt", "not a post");
    const response: Response = await call(context, admin, "GET", "/v1/admin/blog/posts", null);
    expect(response.status).toBe(200);
    const body: ListBody = await response.json<ListBody>();
    expect(body.today).toBe("2026-10-15");
    expect(body.posts.map((post) => [post.slug, post.status, post.sha.slice(0, 1)])).toEqual([
      ["next-week", "scheduled", "c"],
      ["today-post", "live", "b"],
      ["draft-post", "draft", "d"],
      ["older-post", "live", "a"],
    ]);
    expect(body.posts[0]).toEqual({
      slug: "next-week",
      title: "A post scheduled for later",
      description: "A description that is long enough for the content schema to accept it here.",
      author: "Senol Dogan",
      published: "2026-10-22",
      updated: null,
      cover: null,
      draft: false,
      status: "scheduled",
      sha: "c".repeat(40),
    });
  });

  it("klasör yoksa (son yazı da silinmiş) liste boştur; okunamayan yazı açık hata verir", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const empty: ListBody = await (await call(context, admin, "GET", "/v1/admin/blog/posts", null)).json<ListBody>();
    expect(empty.posts).toEqual([]);
    fake.files.set("tagged", { sha: "a".repeat(40), text: postFile("A post with an extra field", "2026-10-01", false).replace("draft: false\n", "draft: false\ntags: [a]\n") });
    const body = await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts", null), 500, "blog_post_invalid");
    expect(body.error.message).toContain("web/src/content/blog/tagged.md");
  });

  it("tek yazı: ön bilgi, gövde ve sürüm; olmayan yazı 404, geçersiz kısa ad 400", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    fake.files.set("today-post", { sha: "b".repeat(40), text: postFile("A post going live today", "2026-10-15", false) });
    const response: Response = await call(context, admin, "GET", "/v1/admin/blog/posts/today-post", null);
    expect(response.status).toBe(200);
    const post: PostBody = await response.json<PostBody>();
    expect(post).toMatchObject({ slug: "today-post", title: "A post going live today", status: "live", sha: "b".repeat(40), draft: false, updated: null, cover: null });
    expect(post.body).toBe("First paragraph.\n\n## Heading\n\nMore text.");
    await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts/missing-post", null), 404, "not_found");
    await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts/Bad_Slug", null), 400, "bad_request");
  });

  it("yeni yazı: dosya sabit biçimde yazılır, commit mesajı başlıktır; aynı kısa ad ikinci kez 409", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const response: Response = await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}));
    expect(response.status).toBe(201);
    const post: PostBody = await response.json<PostBody>();
    expect(post).toMatchObject({ slug: "weekly-notes", status: "scheduled", published: "2026-10-22", updated: null, cover: null, body: "Intro paragraph.\n\n## Section\n\n- one\n- two" });
    expect(fake.files.get("weekly-notes")?.text).toBe(
      [
        "---",
        'title: "Weekly notes: what we shipped"',
        'description: "A \\"quoted\\" summary: colons, # hashes and quotes stay safe inside the front matter."',
        'author: "Senol Dogan"',
        "published: 2026-10-22",
        "draft: false",
        "---",
        "",
        "Intro paragraph.",
        "",
        "## Section",
        "",
        "- one",
        "- two",
        "",
      ].join("\n"),
    );
    expect(post.sha).toBe(fake.files.get("weekly-notes")?.sha);
    expect(fake.commits).toEqual([{ message: "blog: Weekly notes: what we shipped", branch: "main", method: "PUT", deletions: [] }]);

    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ title: "Another post with the same slug" })), 409, "blog_post_exists");
    expect(fake.commits).toHaveLength(1);
  });

  it("kapak ve güncelleme günü: dosyaya yazılır, yanıtta döner; kaldırılınca dosyadan çıkar", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const created: PostBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ published: "2026-10-01", updated: "2026-10-14", cover: "violet" }))).json<PostBody>();
    expect(created).toMatchObject({ updated: "2026-10-14", cover: "violet", status: "live" });
    expect(fake.files.get("weekly-notes")?.text).toContain("\npublished: 2026-10-01\nupdated: 2026-10-14\ncover: violet\ndraft: false\n");
    const cleared: PostBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ published: "2026-10-01", sha: created.sha }))).json<PostBody>();
    expect(cleared).toMatchObject({ updated: null, cover: null });
    expect(fake.files.get("weekly-notes")?.text).not.toMatch(/updated:|cover:/);
  });

  it("güncelleme: bilinen sürümle yazılır; eski sürümle ya da silinmiş yazıda 409 ve hiçbir şey yazılmaz", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const created: PostBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ draft: true }))).json<PostBody>();
    expect(created.status).toBe("draft");
    const updated: Response = await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ sha: created.sha, published: "2026-10-15", body: "Rewritten." }));
    expect(updated.status).toBe(200);
    const post: PostBody = await updated.json<PostBody>();
    expect(post).toMatchObject({ status: "live", body: "Rewritten." });
    expect(post.sha).not.toBe(created.sha);

    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ sha: created.sha })), 409, "blog_conflict");
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/never-created", input({ sha: created.sha })), 409, "blog_conflict");
    expect(fake.commits).toHaveLength(2);
  });

  it("GitHub yazım sırasında çakışma bildirirse 409 blog_conflict", async () => {
    const context: Setup = await setup();
    const { harness, admin, fake } = context;
    const created: PostBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}))).json<PostBody>();
    harness.stub(contentsPrefix, async (request: Request): Promise<Response> => {
      if (request.method === "PUT") {
        return Response.json({ message: "weekly-notes.md does not match" }, { status: 409 });
      }
      const file: FakeFile | undefined = fake.files.get("weekly-notes");
      return Response.json({ type: "file", sha: file?.sha, encoding: "base64", content: githubBase64(file?.text ?? "") });
    });
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ sha: created.sha })), 409, "blog_conflict");
  });

  it("silme: yazı ve görselleri tek commit'te silinir (`blog: remove <kısa ad>`); eski sürüm 409, olmayan yazı 404, sürümsüz 400", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const created: PostBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}))).json<PostBody>();
    fake.images.set("weekly-notes/chart.webp", { sha: "1".repeat(40), bytes: fakeWebp(10, 10, 64) });
    fake.images.set("weekly-notes/screen.webp", { sha: "2".repeat(40), bytes: fakeWebp(10, 10, 64) });
    fake.images.set("other-post/keep.webp", { sha: "3".repeat(40), bytes: fakeWebp(10, 10, 64) });
    await expectError(await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"f".repeat(40)}`, null), 409, "blog_conflict");
    await expectError(await call(context, admin, "DELETE", "/v1/admin/blog/posts/weekly-notes", null), 400, "bad_request");
    const response: Response = await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${created.sha}`, null);
    expect(response.status).toBe(204);
    expect(fake.files.has("weekly-notes")).toBe(false);
    expect([...fake.images.keys()]).toEqual(["other-post/keep.webp"]);
    expect(fake.commits.at(-1)).toEqual({
      message: "blog: remove weekly-notes",
      branch: "main",
      method: "GRAPHQL",
      deletions: ["web/src/content/blog/weekly-notes.md", "web/public/blog/weekly-notes/chart.webp", "web/public/blog/weekly-notes/screen.webp"],
    });
    await expectError(await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${created.sha}`, null), 404, "not_found");
  });

  it("silme: dal arada ilerlerse yeniden okunup silinir (uyarıyla); görselsiz yazıda yalnızca dosya silinir", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const warnings = vi.spyOn(console, "warn");
    const created: PostBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}))).json<PostBody>();
    fake.head.staleOnce = true;
    const response: Response = await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${created.sha}`, null);
    const lines: string[] = warnings.mock.calls.map((args: unknown[]): string => String(args[0]));
    warnings.mockRestore();
    expect(response.status).toBe(204);
    expect(fake.commits.at(-1)?.deletions).toEqual(["web/src/content/blog/weekly-notes.md"]);
    expect(lines.some((line: string): boolean => line.includes('"event":"blog_delete_stale_head"'))).toBe(true);
  });

  it("görsel: yazının klasörüne yazılır (201, yol ve boyutla; commit `blog: image <kısa ad>/<ad>`); aynı ad 409", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}));
    const image: Uint8Array = fakeWebp(1600, 900, 2048);
    const response: Response = await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes/images/team-board.webp", imageBody(image));
    expect(response.status).toBe(201);
    const saved: ImageBody = await response.json<ImageBody>();
    expect(saved).toMatchObject({ path: "/blog/weekly-notes/team-board.webp", bytes: 2048, width: 1600, height: 900 });
    expect(saved.sha).toBe(fake.images.get("weekly-notes/team-board.webp")?.sha);
    expect(fake.images.get("weekly-notes/team-board.webp")?.bytes).toEqual(image);
    expect(fake.commits.at(-1)).toEqual({ message: "blog: image weekly-notes/team-board.webp", branch: "main", method: "PUT", deletions: [] });
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes/images/team-board.webp", imageBody(image)), 409, "blog_image_exists");
    expect(fake.commits).toHaveLength(2);
  });

  it("görsel doğrulaması: yazı yoksa 404; ad, imza, boyut ve genişlik GitHub'a gitmeden reddedilir", async () => {
    const context: Setup = await setup();
    const { harness, admin } = context;
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/never-saved/images/chart.webp", imageBody(fakeWebp(10, 10, 64))), 404, "not_found");
    const before: number = githubRequests(harness).length;
    const path: string = "/v1/admin/blog/posts/weekly-notes/images";
    await expectError(await call(context, admin, "PUT", `${path}/Chart.webp`, imageBody(fakeWebp(10, 10, 64))), 400, "bad_request");
    await expectError(await call(context, admin, "PUT", `${path}/chart.png`, imageBody(fakeWebp(10, 10, 64))), 400, "bad_request");
    await expectError(await call(context, admin, "PUT", `${path}/${"a".repeat(76)}.webp`, imageBody(fakeWebp(10, 10, 64))), 400, "bad_request");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, imageBody(utf8("\u0089PNG\r\n\u001a\n".padEnd(64, "x")))), 415, "unsupported_media_type");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, imageBody(fakeWebp(1601, 900, 64))), 400, "invalid_body");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, imageBody(fakeWebp(1600, 900, blogImageMaxBytes + 1))), 413, "payload_too_large");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, { data: "not base64!" }), 400, "invalid_body");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, { data: base64Encode(fakeWebp(10, 10, 64)), extra: 1 }), 400, "invalid_body");
    expect(githubRequests(harness)).toHaveLength(before);
  });

  it("doğrulama: içerik şemasının sınırları, kısa ad, tarih, boş ya da uzun gövde, çok satırlı başlık; GitHub'a gidilmez", async () => {
    const context: Setup = await setup();
    const { harness, admin } = context;
    const cases: ReadonlyArray<Partial<Record<string, string | boolean | null>>> = [
      { title: "Too short" },
      { title: "x".repeat(91) },
      { description: "x".repeat(49) },
      { description: "x".repeat(171) },
      { author: "" },
      { published: "2026-02-30" },
      { published: "22 Oct 2026" },
      { updated: "2026-10-21" },
      { updated: "2026-13-01" },
      { cover: "teal" },
      { body: "   \n " },
      { body: "x".repeat(60_001) },
      { title: "A title that has\na line break" },
      { sha: "not-a-sha" },
      { extra: "field" },
    ];
    for (const fields of cases) {
      await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input(fields)), 400, "invalid_body");
    }
    const { cover: _cover, ...withoutCover } = input({}) as Record<string, unknown>;
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", withoutCover), 400, "invalid_body");
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/two--dashes", input({})), 400, "bad_request");
    await expectError(await call(context, admin, "PUT", `/v1/admin/blog/posts/${"a".repeat(81)}`, input({})), 400, "bad_request");
    expect(githubRequests(harness)).toHaveLength(0);
    const longest: Response = await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ body: "é".repeat(60_000) }));
    expect(longest.status).toBe(201);
  });

  it("yönetici olmayan her blog ucunda düz 403 alır", async () => {
    const context: Setup = await setup();
    const { harness } = context;
    const user: Session = await signIn(harness);
    const requests: ReadonlyArray<readonly [string, string, object | null]> = [
      ["GET", "/v1/admin/blog/posts", null],
      ["GET", "/v1/admin/blog/posts/weekly-notes", null],
      ["PUT", "/v1/admin/blog/posts/weekly-notes", input({})],
      ["DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"a".repeat(40)}`, null],
      ["PUT", "/v1/admin/blog/posts/weekly-notes/images/chart.webp", imageBody(fakeWebp(10, 10, 64))],
    ];
    for (const [method, path, json] of requests) {
      await expectError(await call(context, user, method, path, json), 403, "forbidden");
    }
    expect(githubRequests(harness)).toHaveLength(0);
  });

  it("jeton girilmemişse her blog ucu 503 blog_unavailable", async () => {
    const context: Setup = await setup();
    const { harness, admin } = context;
    const requests: ReadonlyArray<readonly [string, string, object | null]> = [
      ["GET", "/v1/admin/blog/posts", null],
      ["GET", "/v1/admin/blog/posts/weekly-notes", null],
      ["PUT", "/v1/admin/blog/posts/weekly-notes", input({})],
      ["DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"a".repeat(40)}`, null],
      ["PUT", "/v1/admin/blog/posts/weekly-notes/images/chart.webp", imageBody(fakeWebp(10, 10, 64))],
    ];
    for (const [method, path, json] of requests) {
      await expectError(await harness.call(req(method, path, { token: admin.accessToken, env: context.noTokenEnv, json })), 503, "blog_unavailable");
    }
  });

  it("GitHub reddi 502 upstream_rejected (gövdesi loglanır, jeton loglanmaz); 5xx uyarıyla 3 kez denenir", async () => {
    const context: Setup = await setup();
    const { harness, admin } = context;
    const warnings = vi.spyOn(console, "warn");
    harness.stub("https://api.github.com/graphql", async (): Promise<Response> => Response.json({ message: "Resource not accessible by personal access token" }, { status: 403 }));
    await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts", null), 502, "upstream_rejected");
    await expectError(await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"a".repeat(40)}`, null), 502, "upstream_rejected");
    let attempts: number = 0;
    harness.stub(contentsPrefix, async (): Promise<Response> => {
      attempts += 1;
      return new Response("unavailable", { status: 503 });
    });
    await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts/weekly-notes", null), 502, "upstream_unavailable");
    const lines: string[] = warnings.mock.calls.map((args: unknown[]): string => String(args[0]));
    warnings.mockRestore();
    expect(attempts).toBe(3);
    expect(lines.some((line: string): boolean => line.includes('"event":"github_request_failed"') && line.includes("Resource not accessible"))).toBe(true);
    expect(lines.filter((line: string): boolean => line.includes('"event":"upstream_retry"') && line.includes('"service":"github"'))).toHaveLength(2);
    expect(lines.some((line: string): boolean => line.includes(token))).toBe(false);
  });

  it("CORS ön kontrolü PUT'a izin verir", async () => {
    const context: Setup = await setup();
    const { harness } = context;
    const preflight: Response = await harness.call(
      req("OPTIONS", "/v1/admin/blog/posts/weekly-notes", { headers: { origin: "http://localhost:8788", "access-control-request-method": "PUT" } }),
    );
    expect(preflight.status).toBe(204);
    expect(preflight.headers.get("access-control-allow-methods")).toContain("PUT");
  });
});

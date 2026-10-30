import { describe, expect, it, vi } from "vitest";
import realPostNoBot from "../../web/src/content/blog/meeting-notes-on-mac-without-a-bot.md?raw";
import realPostRecording from "../../web/src/content/blog/record-teams-zoom-google-meet-on-mac.md?raw";
import realPostTasks from "../../web/src/content/blog/turn-a-meeting-into-a-task-list.md?raw";
import { parseBlogFile, serializeBlogPost } from "../src/blog";
import { base64Encode, hexEncode, randomId, utf8 } from "../src/crypto";
import type { Env } from "../src/env";
import { type Harness, type Session, defaultHarness, envWith, expectError, req, signIn, signInWithGoogle } from "./helpers";

const token: string = "github_pat_test_0123456789abcdefghij";
const contentsPrefix: string = "https://api.github.com/repos/senoldogann/AI-Notepad/contents/web/src/content/blog/";

/** Sahte depodaki dosya. */
interface FakeFile {
  sha: string;
  text: string;
}

/** Sahte GitHub: kısa ad → dosya, gelen yazımların commit mesajları ve dalları. */
interface FakeGithub {
  readonly files: Map<string, FakeFile>;
  readonly commits: Array<{ readonly message: string; readonly branch: string; readonly method: string }>;
  readonly extra: Map<string, string>;
}

/** Metnin SHA-1'i (git sürümü yerine; yalnızca biçimi aynı: 40 onaltılık). */
async function sha1(text: string): Promise<string> {
  return hexEncode(new Uint8Array(await crypto.subtle.digest("SHA-1", utf8(text))));
}

/** GitHub'ın base64 biçimi: 60 karakterde bir satır sonu. */
function githubBase64(text: string): string {
  return (base64Encode(utf8(text)).match(/.{1,60}/g) ?? []).join("\n");
}

/** GitHub REST contents ve GraphQL ağacının sahtesi; jeton ve kullanıcı aracısı her istekte denetlenir. */
function stubGithub(harness: Harness): FakeGithub {
  const fake: FakeGithub = { files: new Map(), commits: [], extra: new Map() };
  harness.stub("https://api.github.com/", async (request: Request): Promise<Response> => {
    if (request.headers.get("authorization") !== `Bearer ${token}` || request.headers.get("user-agent") === null) {
      return Response.json({ message: "Bad credentials" }, { status: 401 });
    }
    const url: URL = new URL(request.url);
    if (url.pathname === "/graphql") {
      const body: { variables: { owner: string; name: string; expression: string } } = await request.json();
      expect(body.variables).toEqual({ owner: "senoldogann", name: "AI-Notepad", expression: "main:web/src/content/blog" });
      const entries = [
        ...[...fake.files.entries()].map(([slug, file]: [string, FakeFile]) => ({ name: `${slug}.md`, type: "blob", oid: file.sha, object: { text: file.text, isTruncated: false } })),
        ...[...fake.extra.entries()].map(([name, text]: [string, string]) => ({ name, type: "blob", oid: "e".repeat(40), object: { text, isTruncated: false } })),
      ];
      return Response.json({ data: { repository: { object: entries.length === 0 ? null : { entries } } } });
    }
    const slug: string = decodeURIComponent(request.url.slice(contentsPrefix.length).split("?")[0] ?? "").replace(/\.md$/, "");
    const current: FakeFile | undefined = fake.files.get(slug);
    if (request.method === "GET") {
      expect(url.searchParams.get("ref")).toBe("main");
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
      fake.commits.push({ message: body.message, branch: body.branch, method: "PUT" });
      return Response.json({ content: { sha, name: `${slug}.md` }, commit: { sha: "c".repeat(40) } }, { status: current === undefined ? 201 : 200 });
    }
    if (request.method === "DELETE") {
      if (current === undefined) {
        return Response.json({ message: "Not Found" }, { status: 404 });
      }
      if (current.sha !== body.sha) {
        return Response.json({ message: "conflict" }, { status: 409 });
      }
      fake.files.delete(slug);
      fake.commits.push({ message: body.message, branch: body.branch, method: "DELETE" });
      return Response.json({ content: null, commit: { sha: "d".repeat(40) } });
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
    draft: false,
    body: "Intro paragraph.\n\n## Section\n\n- one\n- two\n",
    sha: null,
    ...fields,
  };
}

interface PostBody {
  readonly slug: string;
  readonly title: string;
  readonly description: string;
  readonly author: string;
  readonly published: string;
  readonly draft: boolean;
  readonly status: string;
  readonly sha: string;
  readonly body: string;
}

interface ListBody {
  readonly today: string;
  readonly posts: ReadonlyArray<Omit<PostBody, "body">>;
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
    const frontMatter = { title: 'Say "hi": #1 \\ tips — ok', description: "x".repeat(60), author: "Şenol Doğan", published: "2026-11-05", draft: true };
    const text: string = serializeBlogPost(frontMatter, "\n\nBody line\n\n");
    expect(text.startsWith('---\ntitle: "Say \\"hi\\": #1 \\\\ tips — ok"\n')).toBe(true);
    expect(parseBlogFile("x", text)).toEqual({ frontMatter, body: "Body line" });
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
    expect(post).toMatchObject({ slug: "today-post", title: "A post going live today", status: "live", sha: "b".repeat(40), draft: false });
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
    expect(post).toMatchObject({ slug: "weekly-notes", status: "scheduled", published: "2026-10-22", body: "Intro paragraph.\n\n## Section\n\n- one\n- two" });
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
    expect(fake.commits).toEqual([{ message: "blog: Weekly notes: what we shipped", branch: "main", method: "PUT" }]);

    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ title: "Another post with the same slug" })), 409, "blog_post_exists");
    expect(fake.commits).toHaveLength(1);
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

  it("silme: bilinen sürümle silinir (commit `blog: remove <kısa ad>`); eski sürüm 409, olmayan yazı 404, sürümsüz 400", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const created: PostBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}))).json<PostBody>();
    await expectError(await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"f".repeat(40)}`, null), 409, "blog_conflict");
    await expectError(await call(context, admin, "DELETE", "/v1/admin/blog/posts/weekly-notes", null), 400, "bad_request");
    const response: Response = await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${created.sha}`, null);
    expect(response.status).toBe(204);
    expect(fake.files.has("weekly-notes")).toBe(false);
    expect(fake.commits.at(-1)).toEqual({ message: "blog: remove weekly-notes", branch: "main", method: "DELETE" });
    await expectError(await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${created.sha}`, null), 404, "not_found");
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
      { body: "   \n " },
      { body: "x".repeat(60_001) },
      { title: "A title that has\na line break" },
      { sha: "not-a-sha" },
      { extra: "field" },
    ];
    for (const fields of cases) {
      await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input(fields)), 400, "invalid_body");
    }
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/two--dashes", input({})), 400, "bad_request");
    await expectError(await call(context, admin, "PUT", `/v1/admin/blog/posts/${"a".repeat(81)}`, input({})), 400, "bad_request");
    expect(harness.outbound.filter((request: Request): boolean => request.url.startsWith("https://api.github.com/"))).toHaveLength(0);
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
    ];
    for (const [method, path, json] of requests) {
      await expectError(await call(context, user, method, path, json), 403, "forbidden");
    }
    expect(harness.outbound.filter((request: Request): boolean => request.url.startsWith("https://api.github.com/"))).toHaveLength(0);
  });

  it("jeton girilmemişse her blog ucu 503 blog_unavailable", async () => {
    const context: Setup = await setup();
    const { harness, admin } = context;
    const requests: ReadonlyArray<readonly [string, string, object | null]> = [
      ["GET", "/v1/admin/blog/posts", null],
      ["GET", "/v1/admin/blog/posts/weekly-notes", null],
      ["PUT", "/v1/admin/blog/posts/weekly-notes", input({})],
      ["DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"a".repeat(40)}`, null],
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

// Uçtan uca site denemesi: yerel yapılandırmayla derlenmiş site (`npm run build:local`, `scripts/serve.ts`) yerel
// sunucuya (`server/`, `wrangler dev`) karşı başsız Chrome'da sürülür. Denenenler: her sayfada CSP ihlali ve konsol
// hatası olmaması; Mac uygulaması adına giriş (sağlayıcıya doğrudan yönlendirme, geçersiz istek, iki düğme, vazgeçme
// dönüşü, jetonun uygulamaya iletilmesi, `state` uyuşmazlığı); sitenin Google yönlendirmesi ve Apple açılır pencere
// kurulumu (ham nonce'un özeti sağlayıcıya, ham hali sunucuya); hesap sayfası (gerçek `/v1/me`, `?payment=done` oturumlu
// ve oturumsuz, Checkout'a geçiş, davet koduyla Checkout (biçimsiz kod Checkout açmaz, davet bağlantısından gelen kod
// Checkout gövdesine girer), erişim jetonu yenilemesi, çıkış, Enter'la hesap silme); kopyalanan sekmenin oturumu silmesi;
// indirme sayfasındaki sürüm.
// Üçüncü taraflara istek gitmez: Apple'ın betiği ve Turnstile sahte betikle karşılanır, Apple ve Google yetkilendirme
// sayfalarına gidiş yakalanıp durdurulur; kimlik jetonu doğrulaması (Apple/Google JWKS) ve Stripe çağrıları sunucunun
// kendi testlerindedir, burada `/v1/auth/{apple,google}`, `/v1/billing/checkout` ve `/v1/download/mac/version`
// tarayıcıda karşılanır. Diğer API istekleri yerel sunucuya gider; oturum yerel D1'e eklenen yenileme jetonuyla açılır
// (`wrangler d1 execute --local`; üretim veritabanına dokunmaz).
// Kullanım: node scripts/e2e.ts <site adresi> <yerel sunucu adresi> <Chrome yolu>
// Sunucunun SITE_ORIGIN'i site adresi olmalı: `npx wrangler dev --port <p> --var SITE_ORIGIN:<site adresi>`.
import { execFileSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { type Browser, type BrowserContext, type ConsoleMessage, type Page, type Request, type Route, chromium } from "playwright-core";
import { appleAuthScriptUrl, appleAuthorizeUrl, googleAuthorizeUrl, siteConfigs, turnstileScriptUrl } from "../src/config.ts";

/** Bir denetimin sonucu. */
interface Check {
  readonly name: string;
  readonly ok: boolean;
  readonly detail: string;
}

/** Yerel D1'e eklenen oturum. */
interface SeededSession {
  readonly userId: string;
  readonly refreshToken: string;
}

/** Oturumu yazılmış sayfa ve ilk yüklemeden beri toplanan konsol hataları. */
interface SessionPage {
  readonly page: Page;
  readonly errors: string[];
}

/** Sunucunun oturum yanıtı (`/v1/auth/refresh`). */
interface SessionBody {
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly expiresIn: number;
  readonly userId: string;
}

/** Sahte Apple betiğinin `init`'e verilen ayarları. */
interface AppleInit {
  readonly clientId: string;
  readonly scope: string;
  readonly redirectURI: string;
  readonly state: string;
  readonly nonce: string;
  readonly usePopup: boolean;
}

/** Tarayıcıda karşılanan giriş isteğinin gövdesi. */
interface IdentityBody {
  readonly identityToken: string;
  readonly nonce: string;
}

/** Bağlam düzeyindeki yakalamalar: sağlayıcıya gidişler ve tarayıcıda karşılanan giriş istekleri. */
interface Captures {
  readonly providerNavigations: string[];
  readonly identityRequests: Array<{ readonly path: string; readonly body: IdentityBody }>;
  readonly checkoutRequests: string[];
  /** Checkout isteklerinin gövdeleri (seçilen plan ve davet kodu). */
  readonly checkoutBodies: string[];
  /** `/v1/auth/{apple,google}` isteğine verilecek oturum (gerçek yenilemeyle alınır). */
  nextIdentitySession: SessionBody | null;
}

const checks: Check[] = [];
const serverDir: string = fileURLToPath(new URL("../../server/", import.meta.url));
/** Derlemedeki API adresi; istekler yerel sunucuya aktarılır. */
const builtApiBase: string = siteConfigs.local.apiBase;
const hashedNoncePattern: RegExp = /^[0-9a-f]{64}$/;
const fakeIdToken: string = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJlMmUifQ.c2ln";
const appScheme: string = "com.senoldogan.ainotepad.hosted";
/** Giriş uçlarının IP hız sınırı (dakikada 10) aşılınca beklenen süre. */
const authLimitWaitMs: number = 61_000;

/** Denetim sonucunu kaydeder ve yazdırır. */
function check(name: string, ok: boolean, detail: string): void {
  checks.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : ` — ${detail}`}`);
}

/** Metnin SHA-256 onaltılık özeti. Saf fonksiyondur. */
function sha256Hex(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

/** Yerel D1'de SQL çalıştırır (yalnızca `--local`). */
function localSql(command: string): void {
  execFileSync("npx", ["wrangler", "d1", "execute", "ainotepad", "--local", "--command", command], { cwd: serverDir, stdio: "pipe" });
}

/** Sunucunun davet kodu alfabesi (server/src/referrals.ts `referralCodeAlphabet`). */
const referralCodeAlphabet: string = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";

/** Rastgele, sunucu biçiminde (8 karakter) davet kodu. */
function randomReferralCode(): string {
  return Array.from(randomBytes(8), (byte: number): string => referralCodeAlphabet.charAt(byte % referralCodeAlphabet.length)).join("");
}

/**
 * Yerel D1'e davet eden bir abone ekler: kullanıcı, etkin abonelik ve davet kodu (sunucu `requireReferral` kodun
 * sahibinde abonelik erişimi arar). Davet kodunu döndürür.
 */
function seedReferrer(): string {
  const userId: string = `e2e-web-${randomUUID()}`;
  const code: string = randomReferralCode();
  const now: number = Date.now();
  localSql(
    [
      `INSERT INTO users (id, created_at) VALUES ('${userId}', ${now});`,
      `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, last_event_created, updated_at) VALUES ('${userId}', 'cus_${userId}', 'sub_${userId}', 'active', ${now + 30 * 86_400_000}, 1, ${now});`,
      `INSERT INTO referral_codes (user_id, code, created_at) VALUES ('${userId}', '${code}', ${now});`,
    ].join(" "),
  );
  return code;
}

/** Kullanıcıya giriş kimliği ekler (sunucu davet kodunu doğrularken kimliğin özetini alır). */
function seedIdentity(userId: string): void {
  localSql(`INSERT INTO auth_identities (provider, subject, user_id, created_at) VALUES ('google', 'e2e-${randomUUID()}', '${userId}', ${Date.now()});`);
}

/** Yerel D1'e kullanıcı, oturum ailesi ve yenileme jetonu ekler (sunucunun saklama biçimi: SHA-256 onaltılık). */
function seedSession(): SeededSession {
  const refreshToken: string = randomBytes(32).toString("base64url");
  const userId: string = `e2e-web-${randomUUID()}`;
  const familyId: string = `e2e-web-${randomUUID()}`;
  const now: number = Date.now();
  localSql(
    [
      `INSERT INTO users (id, created_at) VALUES ('${userId}', ${now});`,
      `INSERT INTO refresh_families (id, user_id, created_at) VALUES ('${familyId}', '${userId}', ${now});`,
      `INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at) VALUES ('${sha256Hex(refreshToken)}', '${familyId}', ${now}, ${now + 86_400_000});`,
    ].join(" "),
  );
  return { userId, refreshToken };
}

/** Bekler. */
function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve: () => void): void => {
    setTimeout(resolve, milliseconds);
  });
}

/** Yerel sunucuya istek; giriş uçlarının hız sınırında bir dakika beklenip yeniden denenir (en çok 3 kez). */
async function serverFetch(apiBase: string, path: string, init: RequestInit): Promise<Response> {
  for (let attempt: number = 1; ; attempt += 1) {
    const response: Response = await fetch(`${apiBase}${path}`, init);
    if (response.status !== 429 || !path.startsWith("/v1/auth/") || attempt > 3) {
      return response;
    }
    console.log("auth_rate_limited_waiting", { path, attempt });
    await delay(authLimitWaitMs);
  }
}

/** Yenileme jetonuyla gerçek oturum alır. Başarısızsa durumu ve gövdeyi taşıyan hata. */
async function refreshSession(apiBase: string, refreshToken: string): Promise<SessionBody> {
  const response: Response = await serverFetch(apiBase, "/v1/auth/refresh", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ refreshToken }),
  });
  const body: string = await response.text();
  if (response.status !== 200) {
    throw new Error(`/v1/auth/refresh başarısız (durum ${response.status}): ${body}`);
  }
  return JSON.parse(body) as SessionBody;
}

/** CORS başlıkları (tarayıcıda karşılanan yanıtlar için). Saf fonksiyondur. */
function corsHeaders(siteOrigin: string): Record<string, string> {
  return {
    "access-control-allow-origin": siteOrigin,
    "access-control-allow-headers": "authorization, content-type",
    "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
    "content-type": "application/json",
  };
}

/** Sahte Apple betiği: `init` ayarlarını saklar, `signIn` denemenin çözmesini bekler. */
const appleStubScript: string = `window.AppleID = { auth: {
  init: function (options) { window.__appleInits = (window.__appleInits || []).concat([options]); },
  signIn: function () { return new Promise(function (resolve, reject) { window.__appleSignIn = { resolve: resolve, reject: reject }; }); }
} };`;

/** Sahte Turnstile betiği: parçacığı çizmeden doğrulanmış sayar. */
const turnstileStubScript: string = `window.turnstile = {
  render: function (container, options) { setTimeout(function () { options.callback("e2e-token"); }, 0); return "e2e-widget"; },
  reset: function () {}, remove: function () {}
};`;

/** CSP ihlallerini ve hataları sayfa yüklenmeden dinler. */
const problemListenerScript: string = `window.__csp = [];
document.addEventListener("securitypolicyviolation", function (event) {
  window.__csp.push(event.violatedDirective + " " + (event.blockedURI || "inline") + " @" + event.sourceFile + ":" + event.lineNumber);
});`;

/**
 * Yeni tarayıcı bağlamı: API istekleri yerel sunucuya aktarılır (giriş, Checkout ve sürüm uçları karşılanır),
 * üçüncü taraf betikleri sahtedir, sağlayıcı sayfalarına gidiş yakalanır, diğer dış istekler kesilir.
 */
async function newContext(browser: Browser, siteOrigin: string, apiBase: string, captures: Captures): Promise<BrowserContext> {
  const context: BrowserContext = await browser.newContext();
  await context.addInitScript(problemListenerScript);
  await context.route("**/*", async (route: Route): Promise<void> => {
    const request: Request = route.request();
    const url: URL = new URL(request.url());
    if (url.origin === siteOrigin) {
      await route.continue();
      return;
    }
    if (request.url() === appleAuthScriptUrl) {
      await route.fulfill({ status: 200, contentType: "text/javascript", body: appleStubScript });
      return;
    }
    if (request.url() === turnstileScriptUrl) {
      await route.fulfill({ status: 200, contentType: "text/javascript", body: turnstileStubScript });
      return;
    }
    if (request.url().startsWith(googleAuthorizeUrl) || request.url().startsWith(appleAuthorizeUrl)) {
      captures.providerNavigations.push(request.url());
      await route.fulfill({ status: 200, contentType: "text/html", body: "<!doctype html><title>provider</title><p>provider</p>" });
      return;
    }
    if (url.origin === "https://checkout.stripe.com") {
      await route.fulfill({ status: 200, contentType: "text/html", body: "<!doctype html><title>checkout</title><p>checkout</p>" });
      return;
    }
    if (url.origin === builtApiBase) {
      await answerApi(route, request, url, siteOrigin, apiBase, captures);
      return;
    }
    console.warn("external_request_blocked", { url: request.url() });
    await route.abort("blockedbyclient");
  });
  return context;
}

/** API isteği: ön kontrol, giriş, Checkout ve sürüm tarayıcıda; diğerleri yerel sunucuya aktarılır. */
async function answerApi(route: Route, request: Request, url: URL, siteOrigin: string, apiBase: string, captures: Captures): Promise<void> {
  const cors: Record<string, string> = corsHeaders(siteOrigin);
  if (request.method() === "OPTIONS") {
    await route.fulfill({ status: 204, headers: cors });
    return;
  }
  if (url.pathname === "/v1/auth/apple" || url.pathname === "/v1/auth/google") {
    captures.identityRequests.push({ path: url.pathname, body: JSON.parse(request.postData() ?? "{}") as IdentityBody });
    const session: SessionBody | null = captures.nextIdentitySession;
    captures.nextIdentitySession = null;
    await route.fulfill(
      session === null
        ? { status: 401, headers: cors, body: JSON.stringify({ error: { code: "invalid_token", message: "e2e: oturum hazırlanmadı" } }) }
        : { status: 200, headers: cors, body: JSON.stringify(session) },
    );
    return;
  }
  if (url.pathname === "/v1/billing/checkout") {
    captures.checkoutRequests.push(request.headers()["authorization"] ?? "");
    captures.checkoutBodies.push(request.postData() ?? "");
    await route.fulfill({ status: 200, headers: cors, body: JSON.stringify({ url: "https://checkout.stripe.com/c/pay/e2e" }) });
    return;
  }
  if (url.pathname === "/v1/download/mac/version") {
    await route.fulfill({ status: 200, headers: cors, body: JSON.stringify({ version: "9.8.7" }) });
    return;
  }
  // Yalnızca sunucunun okuduğu başlıklar aktarılır (bağlantı başlıkları fetch'te yasaktır).
  const incoming: Record<string, string> = request.headers();
  const headers: Record<string, string> = Object.fromEntries(
    ["authorization", "content-type"].flatMap((name: string): Array<[string, string]> => {
      const value: string | undefined = incoming[name];
      return value === undefined ? [] : [[name, value]];
    }),
  );
  headers["origin"] = siteOrigin;
  const response: Response = await serverFetch(apiBase, `${url.pathname}${url.search}`, {
    method: request.method(),
    headers,
    body: request.method() === "GET" || request.method() === "HEAD" ? null : request.postData(),
  });
  // fetch gövdeyi açtığı için sıkıştırma ve uzunluk başlıkları aktarılmaz.
  const responseHeaders: Record<string, string> = Object.fromEntries(
    [...response.headers.entries()].filter(([name]: [string, string]): boolean => name !== "content-encoding" && name !== "content-length"),
  );
  await route.fulfill({ status: response.status, headers: responseHeaders, body: Buffer.from(await response.arrayBuffer()) });
}

/** Sayfanın hatalarını toplar (konsol hatası ve yakalanmamış istisna). */
function watchConsole(page: Page): string[] {
  const errors: string[] = [];
  page.on("console", (message: ConsoleMessage): void => {
    if (message.type() === "error") {
      errors.push(message.text());
    }
  });
  page.on("pageerror", (error: Error): void => {
    errors.push(`pageerror: ${error.message}`);
  });
  return errors;
}

/** Sayfadaki CSP ihlalleri. */
async function cspViolations(page: Page): Promise<string[]> {
  return page.evaluate((): string[] => (window as unknown as { __csp: string[] }).__csp);
}

/** Öğe görünür mü (gizli sınıfı yok ve yer kaplıyor). */
async function isShown(page: Page, selector: string): Promise<boolean> {
  return page.locator(selector).isVisible();
}

/** Koşul sağlanana dek bekler; sağlanmazsa false. */
async function waitUntil(condition: () => Promise<boolean>, timeoutMs: number): Promise<boolean> {
  const deadline: number = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await condition()) {
      return true;
    }
    await delay(100);
  }
  return false;
}

/** Her sayfada CSP ihlali ve konsol hatası yok (oturumsuz). */
async function checkEveryPageCsp(context: BrowserContext, siteOrigin: string): Promise<void> {
  const pages: ReadonlyArray<{ readonly path: string; readonly ready: string; readonly allowed: RegExp | null }> = [
    { path: "/", ready: "main", allowed: null },
    { path: "/pricing", ready: "main", allowed: null },
    { path: "/download", ready: "#download-version:not([hidden])", allowed: null },
    { path: "/sign-in", ready: "#apple-button:enabled", allowed: null },
    { path: `/sign-in?app=1&nonce=${sha256Hex("csp")}`, ready: "#google-redirect-button:enabled", allowed: null },
    { path: "/contact", ready: "#contact-submit:enabled", allowed: null },
    { path: "/privacy", ready: "main", allowed: null },
    { path: "/terms", ready: "main", allowed: null },
    { path: "/admin", ready: "main", allowed: null },
    // Bilinmeyen adres: tarayıcı 404 yanıtını konsola yazar (hata değil, beklenen).
    { path: "/no-such-page", ready: "main", allowed: /status of 404/ },
  ];
  for (const target of pages) {
    const page: Page = await context.newPage();
    const errors: string[] = watchConsole(page);
    await page.goto(`${siteOrigin}${target.path}`);
    const ready: boolean = await page.locator(target.ready).first().waitFor({ timeout: 10_000 }).then((): boolean => true, (): boolean => false);
    await delay(300);
    const csp: string[] = await cspViolations(page);
    const unexpected: string[] = errors.filter((text: string): boolean => target.allowed === null || !target.allowed.test(text));
    check(`CSP ve konsol temiz: ${target.path}`, ready && csp.length === 0 && unexpected.length === 0, JSON.stringify({ ready, csp, errors: unexpected }));
    if (target.path === "/download") {
      check("indirme sayfası sürümü gösterir", (await page.locator("#download-version-number").textContent()) === "9.8.7", "sürüm etiketi boş");
    }
    await page.close();
  }
  // Denetimin kendisi: sonradan eklenen satır içi stil ve betik CSP'ye takılır ve ihlal olarak sayılır.
  const control: Page = await context.newPage();
  await control.goto(`${siteOrigin}/`);
  await control.evaluate((): void => {
    document.body.setAttribute("style", "outline: 1px solid red");
    const script: HTMLScriptElement = document.createElement("script");
    script.textContent = "window.__inline = true;";
    document.body.append(script);
  });
  await delay(300);
  const caught: string[] = await cspViolations(control);
  check(
    "CSP denetimi satır içi stil ve betiği yakalar (denetim kendini doğrular)",
    caught.some((entry: string): boolean => entry.startsWith("style-src")) && caught.some((entry: string): boolean => entry.startsWith("script-src")),
    JSON.stringify(caught),
  );
  await control.close();
}

/** Uygulama adına giriş senaryoları. */
async function checkAppHandoff(context: BrowserContext, siteOrigin: string, captures: Captures): Promise<void> {
  const hashedNonce: string = sha256Hex(randomUUID());
  const redirectUri: string = `${siteConfigs.local.siteOrigin}/sign-in`;

  for (const provider of ["google", "apple"] as const) {
    const page: Page = await context.newPage();
    const errors: string[] = watchConsole(page);
    const before: number = captures.providerNavigations.length;
    await page.goto(`${siteOrigin}/sign-in?app=1&nonce=${hashedNonce.toUpperCase()}&provider=${provider}`);
    await waitUntil(async (): Promise<boolean> => captures.providerNavigations.length > before, 10_000);
    const target: URL | null = captures.providerNavigations.length > before ? new URL(captures.providerNavigations.at(-1) ?? "") : null;
    const expectedBase: string = provider === "google" ? googleAuthorizeUrl : appleAuthorizeUrl;
    const params: URLSearchParams = target?.searchParams ?? new URLSearchParams();
    const shapeOk: boolean =
      target !== null &&
      `${target.origin}${target.pathname}` === expectedBase &&
      params.get("nonce") === hashedNonce &&
      params.get("redirect_uri") === redirectUri &&
      /^[0-9a-f]{32}$/.test(params.get("state") ?? "") &&
      (provider === "google" ? params.get("response_type") === "id_token" && params.get("prompt") === "select_account" : params.get("response_mode") === "fragment" && params.get("response_type") === "code id_token");
    check(`uygulama girişi provider=${provider} düğmesiz doğrudan sağlayıcıya gider (nonce küçük harfe, state, dönüş adresi)`, shapeOk && errors.length === 0, JSON.stringify({ target: target?.toString() ?? null, errors }));

    // Sağlayıcıdan vazgeçme dönüşü (aynı sekme, bekleyen deneme sessionStorage'da): kendiliğinden yönlendirilmez.
    const state: string = params.get("state") ?? "";
    const afterGo: number = captures.providerNavigations.length;
    const cancelError: string = provider === "google" ? "access_denied" : "user_cancelled_authorize";
    await page.goto(`${siteOrigin}/sign-in#error=${cancelError}&state=${state}`);
    await page.locator("#google-redirect-button:enabled").waitFor({ timeout: 10_000 });
    await delay(500);
    check(
      `uygulama girişi ${provider} vazgeçme dönüşü: yönlendirme yok, iki düğme, bildirim yok, adres nonce'lu sayfaya döner`,
      captures.providerNavigations.length === afterGo &&
        (await page.locator("#apple-button").isEnabled()) &&
        !(await isShown(page, "#signin-error")) &&
        new URL(page.url()).search === `?app=1&nonce=${hashedNonce}` &&
        new URL(page.url()).hash === "",
      JSON.stringify({ url: page.url(), navigations: captures.providerNavigations.length - afterGo }),
    );

    // Vazgeçmeden sonra düğmeyle yeniden dener; dönüş jetonla gelir: jeton uygulamanın şemasıyla iletilir.
    const beforeRetry: number = captures.providerNavigations.length;
    await page.locator(provider === "google" ? "#google-redirect-button" : "#apple-button").click();
    await waitUntil(async (): Promise<boolean> => captures.providerNavigations.length > beforeRetry, 10_000);
    const retryState: string = new URL(captures.providerNavigations.at(-1) ?? "about:blank").searchParams.get("state") ?? "";
    await page.goto(`${siteOrigin}/sign-in#id_token=${fakeIdToken}&state=${retryState}`, { waitUntil: "commit" });
    await page.locator("#signin-app-return").waitFor({ state: "visible", timeout: 10_000 }).catch((): void => undefined);
    const openHref: string | null = await page.locator("#signin-app-open").getAttribute("href");
    check(
      `uygulama girişi ${provider} jeton dönüşü: ${appScheme}://auth/${provider}#idToken=… adresine iletilir, jeton adreste kalmaz`,
      retryState !== "" && openHref === `${appScheme}://auth/${provider}#idToken=${encodeURIComponent(fakeIdToken)}` && !page.url().includes(fakeIdToken),
      JSON.stringify({ openHref, url: page.url() }),
    );
    await page.close();
  }

  // state uyuşmazlığı: jeton uygulamaya iletilmez.
  {
    const page: Page = await context.newPage();
    const before: number = captures.providerNavigations.length;
    await page.goto(`${siteOrigin}/sign-in?app=1&nonce=${hashedNonce}&provider=google`);
    await waitUntil(async (): Promise<boolean> => captures.providerNavigations.length > before, 10_000);
    await page.goto(`${siteOrigin}/sign-in#id_token=${fakeIdToken}&state=${"0".repeat(32)}`);
    await page.locator("#signin-error").waitFor({ state: "visible", timeout: 10_000 }).catch((): void => undefined);
    check(
      "uygulama girişi state uyuşmazlığı: hata gösterilir, jeton iletilmez",
      (await isShown(page, "#signin-error")) && !(await isShown(page, "#signin-app-return")) && (await page.locator("#signin-error").textContent())?.includes("didn't come back") === true,
      JSON.stringify({ error: await page.locator("#signin-error").textContent() }),
    );
    await page.close();
  }

  // Geçersiz istekler: bilinmeyen sağlayıcı ve bozuk nonce hata gösterir, yönlendirmez.
  for (const search of [`?app=1&nonce=${hashedNonce}&provider=facebook`, "?app=1&nonce=abc&provider=google", "?app=1"]) {
    const page: Page = await context.newPage();
    const errors: string[] = watchConsole(page);
    const before: number = captures.providerNavigations.length;
    await page.goto(`${siteOrigin}/sign-in${search}`);
    await page.locator("#signin-error").waitFor({ state: "visible", timeout: 10_000 }).catch((): void => undefined);
    await delay(300);
    check(
      `uygulama girişi geçersiz istek (${search}): hata, düğme yok, yönlendirme yok`,
      (await isShown(page, "#signin-error")) &&
        !(await isShown(page, "#signin-panel")) &&
        captures.providerNavigations.length === before &&
        errors.some((text: string): boolean => text.includes("app_sign_in_invalid")),
      JSON.stringify({ errors }),
    );
    await page.close();
  }

  // Sağlayıcı seçilmeden (0.1.4 uygulaması): iki düğme, yönlendirme yok.
  {
    const page: Page = await context.newPage();
    const before: number = captures.providerNavigations.length;
    await page.goto(`${siteOrigin}/sign-in?app=1&nonce=${hashedNonce}`);
    await page.locator("#google-redirect-button:enabled").waitFor({ timeout: 10_000 });
    await delay(500);
    check(
      "uygulama girişi sağlayıcısız: iki düğme etkin, uygulama metni görünür, yönlendirme yok",
      (await page.locator("#apple-button").isEnabled()) && (await isShown(page, "#signin-app-intro")) && !(await isShown(page, "#signin-intro")) && captures.providerNavigations.length === before,
      "",
    );
    await page.close();
  }

  // Bekleyen deneme olmadan gelen dönüş (başka sekme ya da süresi geçmiş): hata.
  {
    const page: Page = await context.newPage();
    await page.goto(`${siteOrigin}/sign-in#id_token=${fakeIdToken}&state=${"a".repeat(32)}`);
    await page.locator("#signin-error").waitFor({ state: "visible", timeout: 10_000 }).catch((): void => undefined);
    check("bekleyen deneme olmadan dönüş: hata, jeton iletilmez", (await isShown(page, "#signin-error")) && !(await isShown(page, "#signin-app-return")), "");
    await page.close();
  }
}

/** Sitenin kendi girişi: Google yönlendirmesi ve Apple açılır penceresi; ham nonce sunucuya, özeti sağlayıcıya. */
async function checkSiteSignIn(context: BrowserContext, siteOrigin: string, apiBase: string, captures: Captures): Promise<void> {
  // Google: düğme → Google'a yönlendirme; dönüşte jeton ham nonce'la sunucuya, oturum saklanır, hesap sayfası.
  {
    const seeded: SeededSession = seedSession();
    const page: Page = await context.newPage();
    const errors: string[] = watchConsole(page);
    await page.goto(`${siteOrigin}/sign-in`);
    const before: number = captures.providerNavigations.length;
    await page.locator("#google-redirect-button:enabled").click();
    await waitUntil(async (): Promise<boolean> => captures.providerNavigations.length > before, 10_000);
    const target: URL = new URL(captures.providerNavigations.at(-1) ?? "about:blank");
    const state: string = target.searchParams.get("state") ?? "";
    const sentNonce: string = target.searchParams.get("nonce") ?? "";
    check("site Google girişi Google'a nonce özeti ve state ile yönlendirir", hashedNoncePattern.test(sentNonce) && /^[0-9a-f]{32}$/.test(state), target.toString());

    captures.nextIdentitySession = await refreshSession(apiBase, seeded.refreshToken);
    const identityBefore: number = captures.identityRequests.length;
    await page.goto(`${siteOrigin}/sign-in#id_token=${fakeIdToken}&state=${state}`);
    await page.waitForURL(`${siteOrigin}/account`, { timeout: 10_000 }).catch((): void => undefined);
    const sent: IdentityBody | undefined = captures.identityRequests.slice(identityBefore).find((entry): boolean => entry.path === "/v1/auth/google")?.body;
    await page.locator("#account-content:not(.hidden)").waitFor({ timeout: 10_000 }).catch((): void => undefined);
    check(
      "site Google dönüşü: jeton ve özeti Google'a verilen ham nonce sunucuya gider, hesap sayfası gerçek /v1/me ile açılır",
      sent !== undefined && sent.identityToken === fakeIdToken && sha256Hex(sent.nonce) === sentNonce && (await isShown(page, "#account-content")) && errors.length === 0,
      JSON.stringify({ sent, url: page.url(), errors }),
    );
    await page.close();
  }

  // Google vazgeçme dönüşü: bildirim yok, giriş yeniden sunulur, sunucuya istek gitmez.
  {
    const page: Page = await context.newPage();
    await page.goto(`${siteOrigin}/sign-in`);
    const before: number = captures.providerNavigations.length;
    await page.locator("#google-redirect-button:enabled").click();
    await waitUntil(async (): Promise<boolean> => captures.providerNavigations.length > before, 10_000);
    const state: string = new URL(captures.providerNavigations.at(-1) ?? "about:blank").searchParams.get("state") ?? "";
    const identityBefore: number = captures.identityRequests.length;
    await page.goto(`${siteOrigin}/sign-in#error=access_denied&state=${state}`);
    await page.locator("#google-redirect-button:enabled").waitFor({ timeout: 10_000 });
    await delay(300);
    check(
      "site Google vazgeçme dönüşü: bildirim yok, düğmeler hazır, sunucuya istek yok",
      !(await isShown(page, "#signin-error")) && captures.identityRequests.length === identityBefore && new URL(page.url()).hash === "",
      page.url(),
    );
    await page.close();
  }

  // Apple açılır penceresi: init ayarları; vazgeçilince bildirim ve yeni nonce; başarıda ham nonce sunucuya.
  {
    const seeded: SeededSession = seedSession();
    const page: Page = await context.newPage();
    await page.goto(`${siteOrigin}/sign-in`);
    await page.locator("#apple-button:enabled").waitFor({ timeout: 10_000 });
    const firstInit: AppleInit | undefined = (await page.evaluate((): AppleInit[] => (window as unknown as { __appleInits: AppleInit[] }).__appleInits))[0];
    check(
      "site Apple girişi açılır pencere kipinde kurulur (kapsamsız, Services ID, nonce özeti, state)",
      firstInit !== undefined &&
        firstInit.usePopup &&
        firstInit.scope === "" &&
        firstInit.clientId === siteConfigs.local.appleServiceId &&
        firstInit.redirectURI === `${siteConfigs.local.siteOrigin}/sign-in` &&
        hashedNoncePattern.test(firstInit.nonce) &&
        /^[0-9a-f]{32}$/.test(firstInit.state),
      JSON.stringify(firstInit ?? null),
    );

    await page.locator("#apple-button").click();
    await page.evaluate((): void => (window as unknown as { __appleSignIn: { reject: (value: object) => void } }).__appleSignIn.reject({ error: "popup_closed_by_user" }));
    await page.locator("#apple-button:enabled").waitFor({ timeout: 10_000 });
    const inits: AppleInit[] = await page.evaluate((): AppleInit[] => (window as unknown as { __appleInits: AppleInit[] }).__appleInits);
    const second: AppleInit | undefined = inits[1];
    check(
      "site Apple penceresi kapatılınca bildirim gösterilir ve yeni nonce/state ile yeniden hazırlanır",
      (await isShown(page, "#signin-error")) && second !== undefined && second.nonce !== firstInit?.nonce && second.state !== firstInit?.state,
      JSON.stringify({ inits: inits.length }),
    );

    captures.nextIdentitySession = await refreshSession(apiBase, seeded.refreshToken);
    const identityBefore: number = captures.identityRequests.length;
    await page.locator("#apple-button").click();
    await page.evaluate(
      (state: string): void =>
        (window as unknown as { __appleSignIn: { resolve: (value: object) => void } }).__appleSignIn.resolve({ authorization: { id_token: "a.b.c", code: "c", state } }),
      second?.state ?? "",
    );
    await page.waitForURL(`${siteOrigin}/account`, { timeout: 10_000 }).catch((): void => undefined);
    const sent: IdentityBody | undefined = captures.identityRequests.slice(identityBefore).find((entry): boolean => entry.path === "/v1/auth/apple")?.body;
    check(
      "site Apple başarılı giriş: ham nonce (özeti Apple'a verilen) sunucuya gider, hesap sayfasına geçilir",
      sent !== undefined && sha256Hex(sent.nonce) === second?.nonce && page.url() === `${siteOrigin}/account`,
      JSON.stringify({ sent, url: page.url() }),
    );
    await page.close();
  }
}

/**
 * Sayfaya bu sekmenin oturumunu (gerçek sunucu oturumu) yazar ve verilen adresi açar. Konsol hataları sayfa açılır
 * açılmaz toplanır: modülün ilk çalışması ve süresi dolmuş jetonun yenilenmesi de denetime girer.
 */
async function openWithSession(context: BrowserContext, siteOrigin: string, path: string, session: SessionBody, accessExpiresAt: number): Promise<SessionPage> {
  const page: Page = await context.newPage();
  const errors: string[] = watchConsole(page);
  await page.goto(`${siteOrigin}/privacy`);
  await page.evaluate(
    ({ stored }: { stored: string }): void => {
      sessionStorage.setItem("gistsmith.session", stored);
    },
    { stored: JSON.stringify({ accessToken: session.accessToken, refreshToken: session.refreshToken, accessExpiresAt }) },
  );
  await page.goto(`${siteOrigin}${path}`);
  return { page, errors };
}

/** Sekmede saklanan oturum. */
async function storedSession(page: Page): Promise<{ accessToken: string; refreshToken: string } | null> {
  return page.evaluate((): { accessToken: string; refreshToken: string } | null => {
    const raw: string | null = sessionStorage.getItem("gistsmith.session");
    return raw === null ? null : (JSON.parse(raw) as { accessToken: string; refreshToken: string });
  });
}

/** Hesap sayfası, çıkış, silme ve kopyalanan sekme. */
async function checkAccount(context: BrowserContext, siteOrigin: string, apiBase: string, captures: Captures): Promise<void> {
  // Oturumsuz: hesap sayfası giriş sayfasına; `?payment=done` ise "ödeme alındı" kartı ve sorgu silinir.
  {
    const page: Page = await context.newPage();
    await page.goto(`${siteOrigin}/account`);
    await page.waitForURL(`${siteOrigin}/sign-in`, { timeout: 10_000 }).catch((): void => undefined);
    check("oturumsuz hesap sayfası giriş sayfasına gider", page.url() === `${siteOrigin}/sign-in`, page.url());
    const errors: string[] = watchConsole(page);
    await page.goto(`${siteOrigin}/account?payment=done`);
    await page.locator("#payment-done-signed-out").waitFor({ state: "visible", timeout: 10_000 }).catch((): void => undefined);
    check(
      "oturumsuz ?payment=done: ödeme alındı kartı, yükleniyor ve çıkış gizli, sorgu silinir, giriş sayfasına gidilmez",
      (await isShown(page, "#payment-done-signed-out")) &&
        !(await isShown(page, "#account-loading")) &&
        !(await isShown(page, "#signout-button")) &&
        page.url() === `${siteOrigin}/account` &&
        errors.length === 0 &&
        (await cspViolations(page)).length === 0,
      JSON.stringify({ url: page.url(), errors }),
    );
    await page.close();
  }

  // Oturumlu: deneme başlamamış hesap gerçek /v1/me ile; erişim jetonu süresi dolmuşsa yenilenir (jeton döner).
  const seeded: SeededSession = seedSession();
  const session: SessionBody = await refreshSession(apiBase, seeded.refreshToken);
  const { page, errors }: SessionPage = await openWithSession(context, siteOrigin, "/account", session, Date.now() - 1000);
  await page.locator("#account-content:not(.hidden)").waitFor({ timeout: 10_000 }).catch((): void => undefined);
  const renewed: { accessToken: string; refreshToken: string } | null = await storedSession(page);
  check(
    "hesap sayfası süresi dolmuş erişim jetonunu hatasız yeniler (yenileme jetonu döner) ve deneme planını gösterir",
    errors.length === 0 &&
      (await isShown(page, "#account-content")) &&
      renewed !== null &&
      renewed.refreshToken !== session.refreshToken &&
      (await isShown(page, "#subscribe-button")) &&
      !(await isShown(page, "#manage-button")) &&
      (await page.locator("#plan-status").textContent()) !== "",
    JSON.stringify({ errors, status: await page.locator("#plan-status").textContent() }),
  );
  // Eski (dönmüş) yenileme jetonu artık geçmez (30 sn içindeki kayıp yanıt payı dışında aile düşmez; burada yalnızca
  // dönüşün sunucuda olduğu denetlenir: yeni jeton çalışır).
  const rotated: SessionBody = await refreshSession(apiBase, renewed?.refreshToken ?? "");
  check("sitenin döndürdüğü yenileme jetonu sunucuda geçerli", rotated.userId === seeded.userId, rotated.userId);
  await page.evaluate(
    ({ stored }: { stored: string }): void => {
      sessionStorage.setItem("gistsmith.session", stored);
    },
    { stored: JSON.stringify({ accessToken: rotated.accessToken, refreshToken: rotated.refreshToken, accessExpiresAt: Date.now() + rotated.expiresIn * 1000 }) },
  );

  // Abone ol: Checkout adresine geçilir (Stripe çağrısı tarayıcıda karşılanır).
  const checkoutBefore: number = captures.checkoutRequests.length;
  await page.reload();
  await page.locator("#subscribe-button:visible").click();
  await page.waitForURL("https://checkout.stripe.com/**", { timeout: 10_000 }).catch((): void => undefined);
  check(
    "Abone ol düğmesi kimlikli Checkout isteği (önceden seçili yıllık planla) atar ve Checkout adresine geçer",
    captures.checkoutRequests.length === checkoutBefore + 1 &&
      captures.checkoutRequests.at(-1)?.startsWith("Bearer ") === true &&
      captures.checkoutBodies.at(-1) === JSON.stringify({ plan: "yearly" }) &&
      page.url().startsWith("https://checkout.stripe.com/"),
    JSON.stringify({ url: page.url(), body: captures.checkoutBodies.at(-1) }),
  );

  // Davetle abone olma (yeni bir hesapla): davet bağlantısından gelen kod hesap sayfasında sunucuda doğrulanır ve
  // Checkout gövdesine girer; alana biçimsiz bir kod yazılıp Abone ol'a basılırsa Checkout açılmaz, neden satırda yazar.
  {
    const code: string = seedReferrer();
    const friend: SeededSession = seedSession();
    seedIdentity(friend.userId);
    const friendSession: SessionBody = await refreshSession(apiBase, friend.refreshToken);
    const invitePage: Page = await context.newPage();
    await invitePage.goto(`${siteOrigin}/invite?code=${code}`);
    await invitePage.locator("#invite-code-box:not(.hidden)").waitFor({ timeout: 10_000 }).catch((): void => undefined);
    await invitePage.close();
    const { page: friendPage, errors: friendErrors }: SessionPage = await openWithSession(
      context,
      siteOrigin,
      "/account",
      friendSession,
      Date.now() + friendSession.expiresIn * 1000,
    );
    await friendPage.locator("#invite-status.invite__ok").waitFor({ timeout: 10_000 }).catch((): void => undefined);
    const prefilled: boolean = await isShown(friendPage, "#invite-status.invite__ok");

    const checkoutsBeforeTypo: number = captures.checkoutRequests.length;
    await friendPage.locator("#invite-input").fill("K7M2");
    await friendPage.locator("#subscribe-button").click();
    await friendPage.locator("#invite-status.invite__error").waitFor({ timeout: 10_000 }).catch((): void => undefined);
    check(
      "hesap sayfası: biçimsiz davet koduyla Abone ol Checkout açmaz, neden davet satırında yazar",
      (await isShown(friendPage, "#invite-status.invite__error")) && captures.checkoutRequests.length === checkoutsBeforeTypo && friendPage.url() === `${siteOrigin}/account`,
      JSON.stringify({ url: friendPage.url(), status: await friendPage.locator("#invite-status").textContent() }),
    );

    await friendPage.locator("#invite-input").fill(code);
    await friendPage.locator("#subscribe-button").click();
    await friendPage.waitForURL("https://checkout.stripe.com/**", { timeout: 10_000 }).catch((): void => undefined);
    check(
      "davet bağlantısından gelen kod hesap sayfasında doğrulanır ve Checkout gövdesine (önceden seçili yıllık planla) girer",
      prefilled && captures.checkoutBodies.at(-1) === JSON.stringify({ plan: "yearly", referralCode: code }) && friendErrors.length === 0,
      JSON.stringify({ prefilled, body: captures.checkoutBodies.at(-1), errors: friendErrors }),
    );
    await friendPage.close();
    // Kayıtlı davet kodu sonraki hesap sayfalarını etkilemesin.
    const cleanup: Page = await context.newPage();
    await cleanup.goto(`${siteOrigin}/privacy`);
    await cleanup.evaluate((): void => window.localStorage.removeItem("gistsmith.invite"));
    await cleanup.close();
  }

  // Webhook'un yazdığı etkin abonelik: `?payment=done` bildirimi, Yönet düğmesi, saat kartı.
  const periodEnd: number = Date.now() + 30 * 86_400_000;
  localSql(
    `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, last_event_created, updated_at) VALUES ('${seeded.userId}', 'cus_${seeded.userId}', 'sub_${seeded.userId}', 'active', ${periodEnd}, 1, ${Date.now()});`,
  );
  await page.goto(`${siteOrigin}/account?payment=done`);
  await page.locator("#account-content:not(.hidden)").waitFor({ timeout: 15_000 }).catch((): void => undefined);
  check(
    "oturumlu ?payment=done: bildirim, abonelik görünür (Yönet, saat kartı), sorgu silinir",
    (await isShown(page, "#payment-done")) && (await isShown(page, "#manage-button")) && !(await isShown(page, "#subscribe-button")) && (await isShown(page, "#hours-card")) && page.url() === `${siteOrigin}/account`,
    JSON.stringify({ url: page.url() }),
  );

  // Kopyalanan sekme: sahibi açıkken aynı sekme kimliği ve oturumla açılan sekme oturumu kullanmadan siler.
  const tabStorage: { session: string | null; tab: string | null } = await page.evaluate((): { session: string | null; tab: string | null } => ({
    session: sessionStorage.getItem("gistsmith.session"),
    tab: sessionStorage.getItem("gistsmith.tab"),
  }));
  const duplicate: Page = await context.newPage();
  const duplicateErrors: string[] = [];
  duplicate.on("console", (message: ConsoleMessage): void => {
    duplicateErrors.push(`${message.type()}: ${message.text()}`);
  });
  await duplicate.addInitScript(
    ({ stored, tab }: { stored: string; tab: string }): void => {
      if (sessionStorage.getItem("e2e.copied") === null) {
        sessionStorage.setItem("e2e.copied", "1");
        sessionStorage.setItem("gistsmith.session", stored);
        sessionStorage.setItem("gistsmith.tab", tab);
      }
    },
    { stored: tabStorage.session ?? "", tab: tabStorage.tab ?? "" },
  );
  await duplicate.goto(`${siteOrigin}/account`);
  await duplicate.waitForURL(`${siteOrigin}/sign-in`, { timeout: 10_000 }).catch((): void => undefined);
  const duplicateTab: string | null = await duplicate.evaluate((): string | null => sessionStorage.getItem("gistsmith.tab"));
  await page.reload();
  await page.locator("#account-content:not(.hidden)").waitFor({ timeout: 10_000 }).catch((): void => undefined);
  check(
    "kopyalanan sekme kopyalanan oturumu siler ve girişe gider; asıl sekmenin oturumu sürer",
    duplicate.url() === `${siteOrigin}/sign-in` &&
      duplicateErrors.some((text: string): boolean => text.includes("tab_session_duplicate")) &&
      duplicateTab !== tabStorage.tab &&
      (await isShown(page, "#account-content")),
    JSON.stringify({ duplicateUrl: duplicate.url(), duplicateErrors }),
  );
  await duplicate.close();

  // Çıkış: sunucuda oturum ailesi düşer, ana sayfaya gidilir.
  const beforeSignOut: { accessToken: string; refreshToken: string } | null = await storedSession(page);
  await page.locator("#signout-button").click();
  await page.waitForURL(`${siteOrigin}/`, { timeout: 10_000 }).catch((): void => undefined);
  const afterSignOut: Response = await serverFetch(apiBase, "/v1/auth/refresh", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ refreshToken: beforeSignOut?.refreshToken ?? "" }),
  });
  check(
    "çıkış ana sayfaya döner, sekmenin oturumu silinir, yenileme jetonu sunucuda geçersizdir",
    page.url() === `${siteOrigin}/` && (await storedSession(page)) === null && afterSignOut.status === 401,
    JSON.stringify({ url: page.url(), refreshStatus: afterSignOut.status }),
  );
  check("hesap sayfası akışında konsol hatası yok", errors.length === 0, JSON.stringify(errors));
  await page.close();

  // Hesap silme: onay kelimesi yazılmadan düğme kapalı; silinince kart, oturum silinir, jeton geçersiz.
  {
    const deleting: SeededSession = seedSession();
    const deletingSession: SessionBody = await refreshSession(apiBase, deleting.refreshToken);
    const { page: deletePage }: SessionPage = await openWithSession(context, siteOrigin, "/account", deletingSession, Date.now() + deletingSession.expiresIn * 1000);
    await deletePage.locator("#account-content:not(.hidden)").waitFor({ timeout: 10_000 });
    // Silme bölümü varsayılan kapalıdır (`<details>`).
    await deletePage.locator(".danger__summary").click();
    await deletePage.locator("#delete-button").click();
    const word: string = (await deletePage.locator("#delete-dialog").getAttribute("data-confirm-word")) ?? "";
    const disabledBefore: boolean = await deletePage.locator("#confirm-delete").isDisabled();
    // Onay kelimesi yazılmadan Enter pencereyi kapatmaz ve bir şey silmez.
    await deletePage.locator("#confirm-input").press("Enter");
    const openAfterEarlyEnter: boolean = await deletePage.locator("#delete-dialog").evaluate((dialog: HTMLDialogElement): boolean => dialog.open);
    await deletePage.locator("#confirm-input").fill(word);
    // Kelime yazılınca Enter silme düğmesine basar (pencereyi kapatan örtük form gönderimi değil).
    await deletePage.locator("#confirm-input").press("Enter");
    await deletePage.locator("#account-deleted").waitFor({ state: "visible", timeout: 10_000 }).catch((): void => undefined);
    const me: Response = await fetch(`${apiBase}/v1/me`, { headers: { authorization: `Bearer ${deletingSession.accessToken}` } });
    check(
      "hesap silme: onay kelimesiyle açılır, Enter siler, silindi kartı, oturum silinir, sunucuda hesap yok",
      disabledBefore && openAfterEarlyEnter && word !== "" && (await isShown(deletePage, "#account-deleted")) && (await storedSession(deletePage)) === null && me.status === 401,
      JSON.stringify({ word, openAfterEarlyEnter, meStatus: me.status }),
    );
    await deletePage.waitForURL(`${siteOrigin}/`, { timeout: 10_000 }).catch((): void => undefined);
    check("hesap silindikten sonra ana sayfaya dönülür", deletePage.url() === `${siteOrigin}/`, deletePage.url());
    await deletePage.close();
  }
}

/** Denemeyi çalıştırır. */
async function main(): Promise<void> {
  const [siteOrigin, apiBase, chromePath] = process.argv.slice(2);
  if (siteOrigin === undefined || apiBase === undefined || chromePath === undefined) {
    throw new Error("Kullanım: node scripts/e2e.ts <site adresi> <yerel sunucu adresi> <Chrome yolu>");
  }
  const health: Response = await fetch(`${apiBase}/v1/health`);
  if (health.status !== 200) {
    throw new Error(`Yerel sunucu hazır değil: ${apiBase}/v1/health durum ${health.status}`);
  }
  const captures: Captures = { providerNavigations: [], identityRequests: [], checkoutRequests: [], checkoutBodies: [], nextIdentitySession: null };
  const browser: Browser = await chromium.launch({ executablePath: chromePath, headless: true });
  try {
    const context: BrowserContext = await newContext(browser, siteOrigin, apiBase, captures);
    await checkEveryPageCsp(context, siteOrigin);
    await checkAppHandoff(context, siteOrigin, captures);
    await checkSiteSignIn(context, siteOrigin, apiBase, captures);
    await checkAccount(context, siteOrigin, apiBase, captures);
    await context.close();
  } finally {
    await browser.close();
  }
  const failed: Check[] = checks.filter((entry: Check): boolean => !entry.ok);
  console.log(JSON.stringify({ event: "e2e_done", passed: checks.length - failed.length, failed: failed.length }));
  process.exitCode = failed.length === 0 ? 0 : 1;
}

await main();

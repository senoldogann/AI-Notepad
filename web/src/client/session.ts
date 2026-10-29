// Oturum: jetonlar bellekte ve sekmeye özgü sessionStorage'da tutulur (localStorage yok; sekme kapanınca biter).
// Erişim jetonu süresi dolmadan ve sunucu 401 döndüğünde bir kez `/v1/auth/refresh` ile yenilenir; yenileme jetonu
// her yenilemede döner (eski jeton yeniden kullanılırsa sunucu tüm oturum ailesini düşürür). Kopyalanan sekme
// sessionStorage'ı da kopyalar; iki sekme aynı yenileme jetonunu kullanınca sunucu bunu çalıntı sayıp ikisini de
// düşürürdü. Bu yüzden her sekmenin kimliği vardır ve kopya, sahibi açıkken kopyalanmış oturumu kullanmadan siler
// (`claimTabSession`).
import { type ApiCall, ApiRequestError, type RawResponse, type SessionTokens, parseSession, send } from "./api";

const storageKey: string = "gistsmith.session";
/** Sekmenin kimliği (sessionStorage; kopyalanan sekmeye de kopyalanır). */
const tabKey: string = "gistsmith.tab";
/** Sekmeler arası soru ve cevap kanalı. */
const tabChannelName: string = "gistsmith.tabs";
/** Sahip sekmenin cevabı için beklenen süre. */
const tabClaimWaitMs: number = 150;

/** Sekmeler arası ileti: "bu kimlik kimin?" ve "benim". */
interface TabMessage {
  readonly type: "who" | "mine";
  readonly tabId: string;
}

/** İletinin biçimi doğru mu. Saf fonksiyondur. */
function isTabMessage(value: unknown): value is TabMessage {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const candidate: { type?: unknown; tabId?: unknown } = value as { type?: unknown; tabId?: unknown };
  return (candidate.type === "who" || candidate.type === "mine") && typeof candidate.tabId === "string";
}
/** Erişim jetonu bu kadar süre kala yenilenir. */
const refreshMarginMs: number = 30_000;

/** Saklanan oturum. */
interface StoredSession {
  readonly accessToken: string;
  readonly refreshToken: string;
  /** Erişim jetonunun bittiği an (Unix ms). */
  readonly accessExpiresAt: number;
}

/** Oturum yok ya da yenilenemedi: kullanıcı yeniden giriş yapmalı. */
export class SignedOutError extends Error {
  override readonly name: string = "SignedOutError";
}

let memory: StoredSession | null = null;
let claiming: Promise<void> | null = null;
let refreshing: Promise<StoredSession> | null = null;

/** Sunucu oturumunu saklanacak biçime çevirir. Saf fonksiyondur. */
function toStored(tokens: SessionTokens, nowMs: number): StoredSession {
  return { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, accessExpiresAt: nowMs + tokens.expiresIn * 1000 };
}

/** sessionStorage'daki oturumu okur; bozuksa siler ve null döner. */
function readStored(): StoredSession | null {
  const raw: string | null = sessionStorage.getItem(storageKey);
  if (raw === null) {
    return null;
  }
  try {
    const parsed: { accessToken?: string; refreshToken?: string; accessExpiresAt?: number } = JSON.parse(raw) as {
      accessToken?: string;
      refreshToken?: string;
      accessExpiresAt?: number;
    };
    if (typeof parsed.accessToken === "string" && typeof parsed.refreshToken === "string" && typeof parsed.accessExpiresAt === "number") {
      return { accessToken: parsed.accessToken, refreshToken: parsed.refreshToken, accessExpiresAt: parsed.accessExpiresAt };
    }
  } catch (error: unknown) {
    console.warn("session_corrupt", { error: error instanceof Error ? error.message : String(error) });
  }
  sessionStorage.removeItem(storageKey);
  return null;
}

/** Oturumu bellekte ve sessionStorage'da saklar. */
function store(session: StoredSession): void {
  memory = session;
  sessionStorage.setItem(storageKey, JSON.stringify(session));
}

/** Girişten dönen oturumu saklar. */
export function saveSession(tokens: SessionTokens): void {
  store(toStored(tokens, Date.now()));
}

/** Oturumu siler (çıkış, hesap silme, yenilenemeyen oturum). */
export function clearSession(): void {
  memory = null;
  sessionStorage.removeItem(storageKey);
}

/** Geçerli oturum (bellek, yoksa sessionStorage); yoksa null. */
function currentSession(): StoredSession | null {
  if (memory === null) {
    memory = readStored();
  }
  return memory;
}

/** Bu sekmede oturum var mı. */
export function hasSession(): boolean {
  return currentSession() !== null;
}

/** Yeni sekme kimliği yazar ve döner. */
function newTabId(): string {
  const tabId: string = crypto.randomUUID();
  sessionStorage.setItem(tabKey, tabId);
  return tabId;
}

/**
 * Oturumu kullanmadan önce çağrılır: bu sekme kopyaysa (aynı kimliğin sahibi açık bir sekmede cevap verir) kopyalanmış
 * oturum silinir ve sekme yeni kimlik alır; kullanıcı bu sekmede yeniden giriş yapar. Sonra sekme kendi kimliği
 * soruldukça "benim" diye cevap verir. BroadcastChannel yoksa (çok eski tarayıcı) kopya algılanamaz ve uyarı loglanır.
 */
export function claimTabSession(): Promise<void> {
  if (claiming === null) {
    claiming = claimOnce();
  }
  return claiming;
}

/** Sayfada bir kez çalışan sahiplik denetimi (üst çubuk ve sayfa betiği aynı sözü paylaşır; ikinci kanal kendi
 * sorusuna cevap vermez). */
async function claimOnce(): Promise<void> {
  if (typeof BroadcastChannel === "undefined") {
    console.warn("tab_claim_unavailable", { reason: "BroadcastChannel yok" });
    return;
  }
  const channel: BroadcastChannel = new BroadcastChannel(tabChannelName);
  let tabId: string = sessionStorage.getItem(tabKey) ?? newTabId();
  const duplicate: boolean = await new Promise((resolve: (found: boolean) => void): void => {
    const onAnswer = (event: MessageEvent): void => {
      if (isTabMessage(event.data) && event.data.type === "mine" && event.data.tabId === tabId) {
        channel.removeEventListener("message", onAnswer);
        resolve(true);
      }
    };
    channel.addEventListener("message", onAnswer);
    channel.postMessage({ type: "who", tabId } satisfies TabMessage);
    setTimeout((): void => {
      channel.removeEventListener("message", onAnswer);
      resolve(false);
    }, tabClaimWaitMs);
  });
  if (duplicate) {
    console.warn("tab_session_duplicate", { action: "kopyalanan oturum silindi" });
    clearSession();
    tabId = newTabId();
  }
  channel.addEventListener("message", (event: MessageEvent): void => {
    if (isTabMessage(event.data) && event.data.type === "who" && event.data.tabId === sessionStorage.getItem(tabKey)) {
      channel.postMessage({ type: "mine", tabId: event.data.tabId } satisfies TabMessage);
    }
  });
}

/** Oturumu yeniler. Aynı anda gelen çağrılar tek isteği paylaşır. Jeton geçersizse oturum silinir, `SignedOutError`. */
async function refresh(session: StoredSession): Promise<StoredSession> {
  if (refreshing === null) {
    refreshing = (async (): Promise<StoredSession> => {
      const path: string = "/v1/auth/refresh";
      try {
        const response: RawResponse = await send({ method: "POST", path, body: { refreshToken: session.refreshToken }, accessToken: null, attempts: 1 });
        const renewed: StoredSession = toStored(parseSession(response, path), Date.now());
        store(renewed);
        return renewed;
      } catch (error: unknown) {
        if (error instanceof ApiRequestError && (error.status === 401 || error.status === 400)) {
          clearSession();
          throw new SignedOutError(`Oturum yenilenemedi (${error.code}).`);
        }
        throw error;
      } finally {
        refreshing = null;
      }
    })();
  }
  return refreshing;
}

/** Kullanıma hazır oturum: süresi dolmak üzereyse önce yenilenir. Oturum yoksa `SignedOutError`. */
async function freshSession(): Promise<StoredSession> {
  const session: StoredSession | null = currentSession();
  if (session === null) {
    throw new SignedOutError("Bu sekmede oturum yok.");
  }
  return session.accessExpiresAt - refreshMarginMs > Date.now() ? session : refresh(session);
}

/** Kimlikli istek tanımı (jeton oturumdan eklenir). */
export type AuthorizedCall = Omit<ApiCall, "accessToken">;

/** Kimlikli istek: erişim jetonu eklenir; sunucu 401 dönerse oturum bir kez yenilenip istek tekrarlanır. */
export async function authorizedSend(call: AuthorizedCall): Promise<RawResponse> {
  const session: StoredSession = await freshSession();
  try {
    return await send({ ...call, accessToken: session.accessToken });
  } catch (error: unknown) {
    if (!(error instanceof ApiRequestError) || error.status !== 401) {
      throw error;
    }
  }
  const renewed: StoredSession = await refresh(session);
  return send({ ...call, accessToken: renewed.accessToken });
}

/** Çıkış: sunucuda oturum ailesi düşürülür, sonra yerel oturum silinir (sunucu hatası yerel çıkışı engellemez). */
export async function signOut(): Promise<void> {
  const session: StoredSession | null = currentSession();
  clearSession();
  if (session !== null) {
    await send({ method: "POST", path: "/v1/auth/logout", body: { refreshToken: session.refreshToken }, accessToken: null, attempts: 2 });
  }
}

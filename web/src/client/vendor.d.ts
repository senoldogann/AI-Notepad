// Dış betiklerin (Apple ile giriş JS, Cloudflare Turnstile) sitenin kullandığı kadarının tipleri.

/** `AppleID.auth.init` ayarları (açılır pencere kipi). */
interface AppleAuthInitOptions {
  readonly clientId: string;
  readonly scope: string;
  readonly redirectURI: string;
  readonly state: string;
  /** Apple'a verilen nonce: ham nonce'un SHA-256 onaltılık özeti. */
  readonly nonce: string;
  readonly usePopup: boolean;
}

/** `AppleID.auth.signIn` başarılı yanıtı. */
interface AppleSignInResponse {
  readonly authorization: {
    readonly id_token: string;
    readonly code: string;
    readonly state: string;
  };
}

/** Apple ile giriş JS'i (appleid.auth.js). */
interface AppleIdGlobal {
  readonly auth: {
    init(options: AppleAuthInitOptions): void;
    signIn(): Promise<AppleSignInResponse>;
  };
}

/** `turnstile.render` ayarları. */
interface TurnstileRenderOptions {
  readonly sitekey: string;
  readonly action: string;
  readonly theme: "auto" | "light" | "dark";
  readonly language: string;
  readonly callback: (token: string) => void;
  readonly "expired-callback": () => void;
  readonly "error-callback": (code: string) => void;
}

/** Cloudflare Turnstile (açık işleme kipi). */
interface TurnstileGlobal {
  render(container: HTMLElement, options: TurnstileRenderOptions): string;
  reset(widgetId: string): void;
}

interface Window {
  AppleID?: AppleIdGlobal;
  turnstile?: TurnstileGlobal;
}

// Dış betiklerin (Apple ile giriş JS, Google Identity Services, Cloudflare Turnstile) sitenin kullandığı kadarının tipleri.

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

/** Google'ın giriş sonucu: `credential` imzalı kimlik jetonudur (JWT). */
interface GoogleCredentialResponse {
  readonly credential: string;
  readonly select_by: string;
}

/** `google.accounts.id.initialize` ayarları. */
interface GoogleIdConfiguration {
  readonly client_id: string;
  readonly callback: (response: GoogleCredentialResponse) => void;
  /** Kimlik jetonunun `nonce` iddiasına olduğu gibi yazılır (burada ham nonce'un SHA-256 özeti). */
  readonly nonce: string;
  readonly ux_mode: "popup";
  readonly auto_select: boolean;
  readonly context: "signin";
  readonly itp_support: boolean;
}

/** `google.accounts.id.renderButton` ayarları. */
interface GoogleButtonConfiguration {
  readonly type: "standard";
  readonly theme: "outline" | "filled_black";
  readonly size: "large";
  readonly text: "continue_with";
  readonly shape: "pill";
  readonly logo_alignment: "left";
  /** Piksel; Google 200–400 arasını kabul eder. */
  readonly width: number;
  readonly locale: string;
}

/** Google Identity Services (gsi/client). */
interface GoogleGlobal {
  readonly accounts: {
    readonly id: {
      initialize(configuration: GoogleIdConfiguration): void;
      renderButton(parent: HTMLElement, options: GoogleButtonConfiguration): void;
    };
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
  remove(widgetId: string): void;
}

interface Window {
  AppleID?: AppleIdGlobal;
  google?: GoogleGlobal;
  turnstile?: TurnstileGlobal;
}

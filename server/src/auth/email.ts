import type { EmailConfig } from "../config";
import { randomToken, sha256Hex } from "../crypto";
import { ApiError } from "../errors";
import { log } from "../log";
import type { Platform } from "../platform";
import { fetchUpstream } from "../upstream";

/** E-posta giriş bağlantısı ömrü: 15 dakika. */
export const emailTokenTtlMs: number = 15 * 60_000;
export const resendUrl: string = "https://api.resend.com/emails";

/** Giriş bağlantısı e-postası. */
export interface LoginEmail {
  readonly to: string;
  readonly link: string;
}

/** E-posta gönderim arayüzü (dış sistem bağlantısı). */
export interface EmailSender {
  send(email: LoginEmail): Promise<void>;
}

/** Geliştirme göndericisi: e-posta göndermez, yalnızca gönderildiğini loglar (adres ve bağlantı yazılmaz). */
export class DevEmailSender implements EmailSender {
  async send(_email: LoginEmail): Promise<void> {
    log("info", "email_login_link_dev", { sent: false });
  }
}

/** Resend ile gönderim; geçici hatalar yeniden denenir. */
export class ResendEmailSender implements EmailSender {
  private readonly platform: Platform;
  private readonly apiKey: string;
  private readonly from: string;

  constructor(platform: Platform, apiKey: string, from: string) {
    this.platform = platform;
    this.apiKey = apiKey;
    this.from = from;
  }

  async send(email: LoginEmail): Promise<void> {
    const idempotencyKey: string = await sha256Hex(email.link);
    await fetchUpstream(
      this.platform,
      "resend",
      resendUrl,
      (): RequestInit => ({
        method: "POST",
        headers: {
          authorization: `Bearer ${this.apiKey}`,
          "content-type": "application/json",
          "idempotency-key": idempotencyKey,
        },
        body: JSON.stringify({
          from: this.from,
          to: [email.to],
          subject: "AI-Notepad giriş bağlantın",
          text: loginEmailText(email.link),
        }),
      }),
      3,
    );
  }
}

/** Yapılandırmaya göre gönderici. */
export function emailSender(platform: Platform, config: EmailConfig): EmailSender {
  return config.kind === "resend" ? new ResendEmailSender(platform, config.apiKey, config.from) : new DevEmailSender();
}

/** E-posta gövdesi. Saf fonksiyondur. */
export function loginEmailText(link: string): string {
  return [
    "AI-Notepad'e girmek için bağlantıya tıkla (15 dakika geçerli, tek kullanımlık):",
    "",
    link,
    "",
    "Bu isteği sen yapmadıysan e-postayı yok sayabilirsin.",
    "",
    "To sign in to AI-Notepad, open the link above (valid for 15 minutes, single use).",
  ].join("\n");
}

/** E-posta adresini karşılaştırma için normalleştirir. Saf fonksiyondur. */
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

/** Tek kullanımlık giriş jetonu oluşturur, karmasını saklar ve bağlantıyı gönderir. */
export async function startEmailLogin(db: D1Database, sender: EmailSender, linkUrl: string, email: string, now: Date): Promise<void> {
  const token: string = randomToken(32);
  await db
    .prepare("INSERT INTO email_login_tokens (token_hash, email, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .bind(await sha256Hex(token), email, now.getTime(), now.getTime() + emailTokenTtlMs)
    .run();
  const link: URL = new URL(linkUrl);
  // Jeton parçada (#): sunucu loglarına ve Referer'a düşmez.
  link.hash = `token=${token}`;
  await sender.send({ to: email, link: link.toString() });
}

/** Giriş jetonunu tek seferlik tüketir ve e-posta adresini döndürür; geçersiz/süresi dolmuş/kullanılmışsa `invalid_token`. */
export async function consumeEmailLogin(db: D1Database, token: string, now: Date): Promise<string> {
  const row: { email: string } | null = await db
    .prepare("UPDATE email_login_tokens SET used_at = ? WHERE token_hash = ? AND used_at IS NULL AND expires_at > ? RETURNING email")
    .bind(now.getTime(), await sha256Hex(token), now.getTime())
    .first<{ email: string }>();
  if (row === null) {
    throw new ApiError("invalid_token", "Giriş bağlantısı geçersiz, süresi dolmuş ya da zaten kullanılmış.");
  }
  return row.email;
}

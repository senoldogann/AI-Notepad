import { z } from "zod";

/** `POST /v1/auth/apple`: Apple kimlik jetonu ve Apple'a SHA-256'sı verilen ham nonce. */
export const appleIdentitySchema = z.strictObject({
  identityToken: z.string().min(20).max(8192),
  nonce: z.string().min(16).max(256),
});

/** `POST /v1/auth/email/start`: e-posta ve Turnstile yanıtı. */
export const emailStartSchema = z.strictObject({
  email: z.email().max(254),
  turnstileToken: z.string().min(1).max(4096),
});

/** `POST /v1/auth/email/verify`: bağlantıdaki tek kullanımlık jeton. */
export const emailVerifySchema = z.strictObject({ token: z.string().min(32).max(128) });

/** `POST /v1/auth/refresh` ve `POST /v1/auth/logout`: yenileme jetonu. */
export const refreshSchema = z.strictObject({ refreshToken: z.string().min(32).max(128) });

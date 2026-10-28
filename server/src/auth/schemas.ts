import { z } from "zod";

/**
 * `POST /v1/auth/apple` ve `POST /v1/auth/google`: sağlayıcının kimlik jetonu ve sağlayıcıya SHA-256'sı verilen ham
 * nonce.
 */
export const identityTokenSchema = z.strictObject({
  identityToken: z.string().min(20).max(8192),
  nonce: z.string().min(16).max(256),
});

/** `POST /v1/auth/refresh` ve `POST /v1/auth/logout`: yenileme jetonu. */
export const refreshSchema = z.strictObject({ refreshToken: z.string().min(32).max(128) });

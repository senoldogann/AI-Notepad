import type { z } from "zod";
import { decodeUtf8Strict } from "./crypto";
import { ApiError, ForbiddenIdentityError } from "./errors";

/** JSON yanıt; güvenlik başlıkları `app.ts` içinde her yanıta eklenir. */
export function jsonResponse(status: number, body: object): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

/** Tek tip hata gövdesi: `{error: {code, message}}`; yönetici reddinde ayrıca çağıranın `identity`'si. */
export function errorResponse(error: ApiError): Response {
  const identity: { identity: string } | Record<string, never> = error instanceof ForbiddenIdentityError ? { identity: error.identity } : {};
  return jsonResponse(error.status, { error: { code: error.code, message: error.message, ...identity } });
}

/**
 * Gövdeyi en çok `maxBytes` bayt okur. `content-length` sınırı aşıyorsa hiç okumaz; başlık yoksa ya da yanlışsa akış
 * sayılarak kesilir. Sınır aşımında `payload_too_large`.
 */
export async function readBodyBytes(request: Request, maxBytes: number): Promise<Uint8Array> {
  const declared: string | null = request.headers.get("content-length");
  if (declared !== null && Number(declared) > maxBytes) {
    throw new ApiError("payload_too_large", `İstek gövdesi en çok ${maxBytes} bayt olabilir.`);
  }
  if (request.body === null) {
    return new Uint8Array(0);
  }
  const reader: ReadableStreamDefaultReader<Uint8Array> = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total: number = 0;
  for (;;) {
    const { done, value }: ReadableStreamReadResult<Uint8Array> = await reader.read();
    if (done) {
      break;
    }
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new ApiError("payload_too_large", `İstek gövdesi en çok ${maxBytes} bayt olabilir.`);
    }
    chunks.push(value);
  }
  const result: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

/** Gövdeyi JSON olarak okur ve şemayla doğrular; geçersizse `invalid_body` (alan yolları mesajdadır, değerler değil). */
export async function readJsonBody<Schema extends z.ZodType>(request: Request, schema: Schema, maxBytes: number): Promise<z.output<Schema>> {
  const contentType: string = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new ApiError("unsupported_media_type", "İstek gövdesi application/json olmalı.");
  }
  const bytes: Uint8Array = await readBodyBytes(request, maxBytes);
  let raw: unknown;
  try {
    raw = JSON.parse(decodeUtf8Strict(bytes));
  } catch {
    throw new ApiError("invalid_body", "İstek gövdesi geçerli JSON değil.");
  }
  return parseWithSchema(schema, raw);
}

/** Değeri şemayla doğrular; hata mesajında yalnızca alan yolları ve sorun kodları yer alır. */
export function parseWithSchema<Schema extends z.ZodType>(schema: Schema, raw: unknown): z.output<Schema> {
  const parsed = schema.safeParse(raw);
  if (!parsed.success) {
    const problems: string = parsed.error.issues
      .slice(0, 5)
      .map((issue: z.core.$ZodIssue): string => `${issue.path.join(".") || "(kök)"}: ${issue.code}`)
      .join("; ");
    throw new ApiError("invalid_body", `İstek gövdesi geçersiz: ${problems}`);
  }
  return parsed.data;
}

/** `Authorization: Bearer <jeton>` başlığındaki jeton; yoksa `unauthorized`. Saf fonksiyondur. */
export function bearerToken(request: Request): string {
  const header: string | null = request.headers.get("authorization");
  const match: RegExpExecArray | null = header === null ? null : /^Bearer ([A-Za-z0-9._~+/=-]+)$/.exec(header);
  if (match === null || match[1] === undefined) {
    throw new ApiError("unauthorized", "Bearer erişim jetonu gerekli.");
  }
  return match[1];
}

/**
 * İsteğe bağlı kimlik: `Authorization` başlığı yoksa null; varsa `bearerToken` gibi geçerli biçimde olmalı (değilse
 * `unauthorized`; bozuk başlık sessizce anonim sayılmaz). Saf fonksiyondur.
 */
export function optionalBearerToken(request: Request): string | null {
  return request.headers.has("authorization") ? bearerToken(request) : null;
}

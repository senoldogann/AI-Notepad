import "reflect-metadata";
import { BasicConstraintsExtension, X509Certificate } from "@peculiar/x509";
import { decode, decodeFirst } from "cborg";
import { z } from "zod";
import type { AttestEnvironment } from "../config";
import { base64Encode, bytesEqual, concatBytes, sha256, utf8 } from "../crypto";
import { DerError, derEcdsaSignatureToRaw, singleOctetString } from "./der";

/** App Attest doğrulaması başarısız: neden mesajdadır, istemciye genel bir hata döner. */
export class AttestationError extends Error {
  override readonly name: string = "AttestationError";
}

/** Apple sertifika uzantıları. */
const nonceExtensionOid: string = "1.2.840.113635.100.8.2";
const aclBlobExtensionOid: string = "1.2.840.113635.100.8.6";
/** macOS'ta SIP ve tam güvenlik açık anahtar erişim politikasının sabit özeti (Apple belgesi). */
export const macAclBlobBase64: string = "MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB";

const aaguidByEnvironment: Readonly<Record<AttestEnvironment, Uint8Array>> = {
  development: utf8("appattestdevelop"),
  production: concatBytes([utf8("appattest"), new Uint8Array(7)]),
};

/** Doğrulama ayarları. */
export interface AttestVerifyOptions {
  /** Kabul edilen App ID'ler: `TEAMID.imzalama-kimliği`. */
  readonly appIds: readonly string[];
  readonly environment: AttestEnvironment;
  /** Kabul edilen başlatma doğrulama kategorileri (ör. 6 = Developer ID). */
  readonly allowedCategories: readonly number[];
  readonly rootPem: string;
  readonly now: Date;
}

/** Doğrulanmış cihaz anahtarı. */
export interface AttestedKey {
  readonly publicKeySpki: Uint8Array;
  readonly validationCategory: number;
  readonly bundleVersion: string;
  readonly receipt: Uint8Array;
}

/** Doğrulanmış onay (assertion). */
export interface VerifiedAssertion {
  readonly counter: number;
}

const bytesSchema = z.instanceof(Uint8Array);
const attestationSchema = z.object({
  fmt: z.literal("apple-appattest"),
  attStmt: z.object({ x5c: z.array(bytesSchema).min(2), receipt: bytesSchema }),
  authData: bytesSchema,
});
const assertionSchema = z.object({ signature: bytesSchema, authenticatorData: bytesSchema });

/** Kimlik doğrulayıcı verisinin ortak alanları. */
interface AuthenticatorData {
  readonly rpIdHash: Uint8Array;
  readonly flags: number;
  readonly counter: number;
  readonly rest: Uint8Array;
}

/** Uzantılardaki Apple alanları. */
interface AppleExtensions {
  readonly validationCategory: number;
  readonly bundleVersion: string;
}

const attestedCredentialFlag: number = 0x40;
const extensionDataFlag: number = 0x80;

/** CBOR'u çözer; bozuksa `AttestationError`. */
function decodeCbor(bytes: Uint8Array): unknown {
  try {
    return decode(bytes, { useMaps: false, rejectDuplicateMapKeys: true, strict: true });
  } catch {
    throw new AttestationError("CBOR çözülemedi");
  }
}

/** rpIdHash (32), bayraklar (1), sayaç (4, büyük uçlu) ve kalan baytlar. Saf fonksiyondur. */
function parseAuthenticatorData(bytes: Uint8Array): AuthenticatorData {
  if (bytes.byteLength < 37) {
    throw new AttestationError("authData çok kısa");
  }
  const view: DataView = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return {
    rpIdHash: bytes.subarray(0, 32),
    flags: view.getUint8(32),
    counter: view.getUint32(33, false),
    rest: bytes.subarray(37),
  };
}

/** Uzantı sözlüğünden Apple başlatma kategorisi ve paket sürümü. */
function parseAppleExtensions(bytes: Uint8Array): AppleExtensions {
  const parsed = z
    .object({ apple_validation_category_01: z.number().int().nonnegative(), apple_bundle_version_01: z.string().min(1) })
    .safeParse(decodeCbor(bytes));
  if (!parsed.success) {
    throw new AttestationError("Apple uzantıları eksik ya da geçersiz");
  }
  return { validationCategory: parsed.data.apple_validation_category_01, bundleVersion: parsed.data.apple_bundle_version_01 };
}

/** rpIdHash izinli App ID'lerden birinin SHA-256'sı mı. */
async function matchesAppId(rpIdHash: Uint8Array, appIds: readonly string[]): Promise<boolean> {
  const hashes: Uint8Array[] = await Promise.all(appIds.map((appId: string): Promise<Uint8Array> => sha256(utf8(appId))));
  return hashes.some((hash: Uint8Array): boolean => bytesEqual(hash, rpIdHash));
}

/** PEM ya da DER sertifikayı ayrıştırır. */
function parseCertificate(raw: Uint8Array | string): X509Certificate {
  try {
    return new X509Certificate(raw);
  } catch {
    throw new AttestationError("Sertifika ayrıştırılamadı");
  }
}

/** Sertifika zinciri: yaprak ← ara ← Apple App Attestation kökü; imzalar ve geçerlilik tarihleri denetlenir. */
async function verifyChain(leaf: X509Certificate, intermediate: X509Certificate, root: X509Certificate, now: Date): Promise<void> {
  const basicConstraints: BasicConstraintsExtension | null = intermediate.getExtension(BasicConstraintsExtension);
  if (basicConstraints === null || !basicConstraints.ca) {
    throw new AttestationError("Ara sertifika CA değil");
  }
  const intermediateValid: boolean = await intermediate.verify({ publicKey: root.publicKey, date: now });
  const leafValid: boolean = await leaf.verify({ publicKey: intermediate.publicKey, date: now });
  if (!intermediateValid || !leafValid) {
    throw new AttestationError("Sertifika zinciri Apple köküne bağlanmıyor");
  }
}

/** Sertifika uzantısındaki tek OCTET STRING. */
function extensionOctets(cert: X509Certificate, oid: string): Uint8Array {
  const extension = cert.getExtension(oid);
  if (extension === null) {
    throw new AttestationError(`Uzantı eksik: ${oid}`);
  }
  try {
    return singleOctetString(new Uint8Array(extension.value));
  } catch (error: unknown) {
    if (error instanceof DerError) {
      throw new AttestationError(`Uzantı çözülemedi: ${oid}`);
    }
    throw error;
  }
}

/** P-256 SPKI'den sıkıştırılmamış nokta (65 bayt). */
async function rawP256PublicKey(spki: Uint8Array): Promise<Uint8Array> {
  const key: CryptoKey = await crypto.subtle.importKey("spki", spki, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
  const exported: ArrayBuffer | JsonWebKey = await crypto.subtle.exportKey("raw", key);
  if (!(exported instanceof ArrayBuffer)) {
    throw new AttestationError("Açık anahtar dışa aktarılamadı");
  }
  return new Uint8Array(exported);
}

/**
 * Apple App Attest onay nesnesini (attestation) Apple'ın belgelediği adımlarla doğrular:
 * 1. x5c zinciri Apple App Attestation köküne bağlanır.
 * 2–4. nonce = SHA256(authData || SHA256(challenge)), yaprak sertifikanın 1.2.840.113635.100.8.2 uzantısına eşittir.
 * macOS: 1.2.840.113635.100.8.6 aclBlob'u SIP ve tam güvenlik özetine eşittir.
 * 5. SHA256(açık anahtar) anahtar kimliğine eşittir.
 * 6. rpIdHash = SHA256(App ID); 7. sayaç 0; 8. aaguid ortamla eşleşir; 9. credentialId anahtar kimliğidir.
 * 10–11. Uzantılardaki başlatma kategorisi izinlidir ve paket sürümü vardır.
 */
export async function verifyAttestation(
  attestation: Uint8Array,
  keyId: Uint8Array,
  challenge: Uint8Array,
  options: AttestVerifyOptions,
): Promise<AttestedKey> {
  const parsed = attestationSchema.safeParse(decodeCbor(attestation));
  if (!parsed.success) {
    throw new AttestationError("Onay nesnesi beklenen biçimde değil");
  }
  const { attStmt, authData } = parsed.data;
  const [leafDer, intermediateDer] = attStmt.x5c;
  if (leafDer === undefined || intermediateDer === undefined) {
    throw new AttestationError("x5c eksik");
  }
  const leaf: X509Certificate = parseCertificate(leafDer);
  await verifyChain(leaf, parseCertificate(intermediateDer), parseCertificate(options.rootPem), options.now);

  const nonce: Uint8Array = await sha256(concatBytes([authData, await sha256(challenge)]));
  if (!bytesEqual(extensionOctets(leaf, nonceExtensionOid), nonce)) {
    throw new AttestationError("nonce eşleşmiyor");
  }
  if (base64Encode(extensionOctets(leaf, aclBlobExtensionOid)) !== macAclBlobBase64) {
    throw new AttestationError("macOS anahtar erişim politikası beklenen değil");
  }

  const publicKeySpki: Uint8Array = new Uint8Array(leaf.publicKey.rawData);
  if (!bytesEqual(await sha256(await rawP256PublicKey(publicKeySpki)), keyId)) {
    throw new AttestationError("Açık anahtar anahtar kimliğiyle eşleşmiyor");
  }

  const data: AuthenticatorData = parseAuthenticatorData(authData);
  if (!(await matchesAppId(data.rpIdHash, options.appIds))) {
    throw new AttestationError("rpIdHash izinli App ID'lerle eşleşmiyor");
  }
  if (data.counter !== 0) {
    throw new AttestationError("Sayaç 0 değil");
  }
  if ((data.flags & attestedCredentialFlag) === 0 || data.rest.byteLength < 18) {
    throw new AttestationError("Kimlik bilgisi verisi eksik");
  }
  if (!bytesEqual(data.rest.subarray(0, 16), aaguidByEnvironment[options.environment])) {
    throw new AttestationError("aaguid ortamla eşleşmiyor");
  }
  const credentialIdLength: number = new DataView(data.rest.buffer, data.rest.byteOffset + 16, 2).getUint16(0, false);
  const credentialId: Uint8Array = data.rest.subarray(18, 18 + credentialIdLength);
  if (!bytesEqual(credentialId, keyId)) {
    throw new AttestationError("credentialId anahtar kimliğiyle eşleşmiyor");
  }
  const extensions: AppleExtensions = attestationExtensions(data.flags, data.rest.subarray(18 + credentialIdLength));
  if (!options.allowedCategories.includes(extensions.validationCategory)) {
    throw new AttestationError(`Başlatma doğrulama kategorisi izinli değil: ${extensions.validationCategory}`);
  }
  return {
    publicKeySpki,
    validationCategory: extensions.validationCategory,
    bundleVersion: extensions.bundleVersion,
    receipt: attStmt.receipt,
  };
}

/** COSE anahtarını atlayıp uzantı sözlüğünü okur; uzantı bayrağı yoksa hata. */
function attestationExtensions(flags: number, coseAndExtensions: Uint8Array): AppleExtensions {
  if ((flags & extensionDataFlag) === 0) {
    throw new AttestationError("Uzantı verisi yok");
  }
  let remainder: Uint8Array;
  try {
    // COSE anahtarı tamsayı anahtarlı bir sözlüktür; yalnızca uzunluğu için çözülür.
    remainder = decodeFirst(coseAndExtensions, { useMaps: true })[1];
  } catch {
    throw new AttestationError("COSE anahtarı çözülemedi");
  }
  return parseAppleExtensions(remainder);
}

/**
 * App Attest onayını (assertion) doğrular: imza SHA256(authenticatorData || SHA256(clientData)) üzerinde saklı açık
 * anahtarla geçerlidir, rpIdHash izinli App ID'dir, sayaç öncekinden büyüktür ve uzantılardaki başlatma kategorisi
 * izinlidir. İstemci verisindeki meydan okumayı çağıran denetler.
 */
export async function verifyAssertion(
  assertion: Uint8Array,
  clientData: Uint8Array,
  publicKeySpki: Uint8Array,
  previousCounter: number,
  options: AttestVerifyOptions,
): Promise<VerifiedAssertion> {
  const parsed = assertionSchema.safeParse(decodeCbor(assertion));
  if (!parsed.success) {
    throw new AttestationError("Onay (assertion) nesnesi beklenen biçimde değil");
  }
  const { signature, authenticatorData } = parsed.data;
  const nonce: Uint8Array = await sha256(concatBytes([authenticatorData, await sha256(clientData)]));
  const key: CryptoKey = await crypto.subtle.importKey("spki", publicKeySpki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  let rawSignature: Uint8Array;
  try {
    rawSignature = derEcdsaSignatureToRaw(signature, 32);
  } catch {
    throw new AttestationError("İmza çözülemedi");
  }
  const valid: boolean = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, rawSignature, nonce);
  if (!valid) {
    throw new AttestationError("İmza geçersiz");
  }
  const data: AuthenticatorData = parseAuthenticatorData(authenticatorData);
  if (!(await matchesAppId(data.rpIdHash, options.appIds))) {
    throw new AttestationError("rpIdHash izinli App ID'lerle eşleşmiyor");
  }
  if (data.counter <= previousCounter) {
    throw new AttestationError("Sayaç artmamış (yeniden oynatma)");
  }
  if ((data.flags & extensionDataFlag) === 0) {
    throw new AttestationError("Uzantı verisi yok");
  }
  const extensions: AppleExtensions = parseAppleExtensions(data.rest);
  if (!options.allowedCategories.includes(extensions.validationCategory)) {
    throw new AttestationError(`Başlatma doğrulama kategorisi izinli değil: ${extensions.validationCategory}`);
  }
  return { counter: data.counter };
}

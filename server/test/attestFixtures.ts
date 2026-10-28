import "reflect-metadata";
import { BasicConstraintsExtension, Extension, X509CertificateGenerator } from "@peculiar/x509";
import { encode } from "cborg";
import { macAclBlobBase64 } from "../src/attest/appAttest";
import { base64Decode, base64Encode, concatBytes, sha256, utf8 } from "../src/crypto";

/**
 * Apple App Attest biçiminde sahte onay nesneleri üretir: kendi kök/ara sertifikamız, Apple uzantıları
 * (nonce 1.2.840.113635.100.8.2, macOS aclBlob 1.2.840.113635.100.8.6), CBOR authData ve DER ECDSA onayları.
 * Doğrulayıcı gerçek Apple kökü yerine bu kökle çalıştırılır.
 */
export interface AttestAuthority {
  readonly rootPem: string;
  readonly intermediateDer: Uint8Array;
  readonly intermediateKey: CryptoKey;
}

/** Cihaz anahtarı (Secure Enclave anahtarının taklidi). */
export interface DeviceKey {
  readonly keyPair: CryptoKeyPair;
  readonly keyId: Uint8Array;
  readonly keyIdBase64: string;
}

/** Onay nesnesi seçenekleri. */
export interface AttestationOptions {
  readonly appId: string;
  readonly aaguid: Uint8Array;
  readonly counter: number;
  readonly validationCategory: number;
  readonly aclBlob: Uint8Array;
}

export const testAppId: string = "TEAMID0000.com.senoldogan.AINotepadHosted";
export const developmentAaguid: Uint8Array = utf8("appattestdevelop");
export const productionAaguid: Uint8Array = concatBytes([utf8("appattest"), new Uint8Array(7)]);
export const macAclBlob: Uint8Array = base64Decode(macAclBlobBase64);

/** Geçerli varsayılan seçenekler (geliştirme ortamı, Developer ID kategorisi). */
export function validAttestationOptions(): AttestationOptions {
  return { appId: testAppId, aaguid: developmentAaguid, counter: 0, validationCategory: 6, aclBlob: macAclBlob };
}

/** ECDSA anahtar üretim parametresi. */
interface EcdsaParams {
  readonly name: "ECDSA";
  readonly namedCurve: "P-256" | "P-384";
}

const ecdsaP256: EcdsaParams = { name: "ECDSA", namedCurve: "P-256" };
const ecdsaP384: EcdsaParams = { name: "ECDSA", namedCurve: "P-384" };

function derTlv(tag: number, content: Uint8Array): Uint8Array {
  const length: number = content.byteLength;
  const header: number[] = length < 0x80 ? [tag, length] : length < 0x100 ? [tag, 0x81, length] : [tag, 0x82, length >> 8, length & 0xff];
  return concatBytes([new Uint8Array(header), content]);
}

/** Apple uzantı değeri: SEQUENCE { [1] { OCTET STRING değer } }. */
function appleExtensionValue(value: Uint8Array): Uint8Array {
  return derTlv(0x30, derTlv(0xa1, derTlv(0x04, value)));
}

async function generateKeyPair(params: EcdsaParams): Promise<CryptoKeyPair> {
  return (await crypto.subtle.generateKey(params, true, ["sign", "verify"])) as CryptoKeyPair;
}

/** Kök (P-384) ve ara sertifika (P-384, CA). */
export async function createAuthority(): Promise<AttestAuthority> {
  const rootKeys: CryptoKeyPair = await generateKeyPair(ecdsaP384);
  const notBefore: Date = new Date(Date.UTC(2025, 0, 1));
  const notAfter: Date = new Date(Date.UTC(2035, 0, 1));
  const root = await X509CertificateGenerator.createSelfSigned({
    name: "CN=Test App Attestation Root CA",
    keys: rootKeys,
    notBefore,
    notAfter,
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    extensions: [new BasicConstraintsExtension(true, undefined, true)],
  });
  const intermediateKeys: CryptoKeyPair = await generateKeyPair(ecdsaP384);
  const intermediate = await X509CertificateGenerator.create({
    subject: "CN=Test App Attestation CA 1",
    issuer: root.subject,
    publicKey: intermediateKeys.publicKey,
    signingKey: rootKeys.privateKey,
    notBefore,
    notAfter,
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    extensions: [new BasicConstraintsExtension(true, 0, true)],
  });
  return { rootPem: root.toString("pem"), intermediateDer: new Uint8Array(intermediate.rawData), intermediateKey: intermediateKeys.privateKey };
}

/** Yeni cihaz anahtarı; anahtar kimliği SHA256(sıkıştırılmamış açık anahtar). */
export async function createDeviceKey(): Promise<DeviceKey> {
  const keyPair: CryptoKeyPair = await generateKeyPair(ecdsaP256);
  const raw: Uint8Array = new Uint8Array((await crypto.subtle.exportKey("raw", keyPair.publicKey)) as ArrayBuffer);
  const keyId: Uint8Array = await sha256(raw);
  return { keyPair, keyId, keyIdBase64: base64Encode(keyId) };
}

function appleExtensionsCbor(validationCategory: number): Uint8Array {
  return encode({ apple_validation_category_01: validationCategory, apple_bundle_version_01: "0.2.0" });
}

/** App Attest onay nesnesi (attestation, base64). */
export async function createAttestation(authority: AttestAuthority, device: DeviceKey, challenge: string, options: AttestationOptions): Promise<string> {
  const raw: Uint8Array = new Uint8Array((await crypto.subtle.exportKey("raw", device.keyPair.publicKey)) as ArrayBuffer);
  const cose: Uint8Array = encode(
    new Map<number, number | Uint8Array>([
      [1, 2],
      [3, -7],
      [-1, 1],
      [-2, raw.subarray(1, 33)],
      [-3, raw.subarray(33, 65)],
    ]),
  );
  const counter: Uint8Array = new Uint8Array(4);
  new DataView(counter.buffer).setUint32(0, options.counter, false);
  const authData: Uint8Array = concatBytes([
    await sha256(utf8(options.appId)),
    new Uint8Array([0x40 | 0x80 | 0x01]),
    counter,
    options.aaguid,
    new Uint8Array([0, device.keyId.byteLength]),
    device.keyId,
    cose,
    appleExtensionsCbor(options.validationCategory),
  ]);
  const nonce: Uint8Array = await sha256(concatBytes([authData, await sha256(utf8(challenge))]));
  const leaf = await X509CertificateGenerator.create({
    subject: "CN=device",
    issuer: "CN=Test App Attestation CA 1",
    publicKey: device.keyPair.publicKey,
    signingKey: authority.intermediateKey,
    notBefore: new Date(Date.UTC(2026, 0, 1)),
    notAfter: new Date(Date.UTC(2027, 0, 1)),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    extensions: [
      new Extension("1.2.840.113635.100.8.2", false, appleExtensionValue(nonce)),
      new Extension("1.2.840.113635.100.8.6", false, appleExtensionValue(options.aclBlob)),
    ],
  });
  const attestation: Uint8Array = encode({
    fmt: "apple-appattest",
    attStmt: { x5c: [new Uint8Array(leaf.rawData), authority.intermediateDer], receipt: utf8("test-receipt") },
    authData,
  });
  return base64Encode(attestation);
}

/** WebCrypto r||s imzasını DER'e çevirir. */
function rawSignatureToDer(raw: Uint8Array): Uint8Array {
  const integer = (bytes: Uint8Array): Uint8Array => {
    let start: number = 0;
    while (start < bytes.byteLength - 1 && bytes[start] === 0) {
      start += 1;
    }
    const trimmed: Uint8Array = bytes.subarray(start);
    const padded: Uint8Array = (trimmed[0] ?? 0) >= 0x80 ? concatBytes([new Uint8Array([0]), trimmed]) : trimmed;
    return derTlv(0x02, padded);
  };
  return derTlv(0x30, concatBytes([integer(raw.subarray(0, 32)), integer(raw.subarray(32, 64))]));
}

/** Hassas istek onayı: `{keyId, assertion, clientData}` (base64). */
export async function createAssertion(
  device: DeviceKey,
  action: string,
  challenge: string,
  counter: number,
  options: AttestationOptions,
): Promise<{ keyId: string; assertion: string; clientData: string }> {
  const clientData: Uint8Array = utf8(JSON.stringify({ action, challenge }));
  const counterBytes: Uint8Array = new Uint8Array(4);
  new DataView(counterBytes.buffer).setUint32(0, counter, false);
  const authenticatorData: Uint8Array = concatBytes([
    await sha256(utf8(options.appId)),
    new Uint8Array([0x80 | 0x01]),
    counterBytes,
    appleExtensionsCbor(options.validationCategory),
  ]);
  const nonce: Uint8Array = await sha256(concatBytes([authenticatorData, await sha256(clientData)]));
  const raw: Uint8Array = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, device.keyPair.privateKey, nonce));
  return {
    keyId: device.keyIdBase64,
    assertion: base64Encode(encode({ signature: rawSignatureToDer(raw), authenticatorData })),
    clientData: base64Encode(clientData),
  };
}

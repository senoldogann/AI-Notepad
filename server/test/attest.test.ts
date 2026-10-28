import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import { verifyAttestation } from "../src/attest/appAttest";
import { appleAppAttestationRootPem } from "../src/attest/appleRoot";
import { utf8 } from "../src/crypto";
import {
  type AttestAuthority,
  type AttestationOptions,
  type DeviceKey,
  createAssertion,
  createAttestation,
  createAuthority,
  createDeviceKey,
  productionAaguid,
  testAppId,
  validAttestationOptions,
} from "./attestFixtures";
import { type Harness, type Session, type StartedMeetingBody, createHarness, envWith, expectError, req, signIn } from "./helpers";

let authority: AttestAuthority;

beforeAll(async () => {
  authority = await createAuthority();
});

async function challenge(harness: Harness, session: Session, purpose: "attest" | "assert"): Promise<string> {
  const response: Response = await harness.call(req("POST", "/v1/device/challenge", { token: session.accessToken, json: { purpose } }));
  expect(response.status).toBe(200);
  return (await response.json<{ challenge: string }>()).challenge;
}

async function attest(harness: Harness, session: Session, device: DeviceKey, options: AttestationOptions): Promise<Response> {
  const value: string = await challenge(harness, session, "attest");
  const attestation: string = await createAttestation(authority, device, value, options);
  return harness.call(req("POST", "/v1/device/attest", { token: session.accessToken, json: { keyId: device.keyIdBase64, attestation, challenge: value } }));
}

async function startWithDevice(harness: Harness, session: Session, device: DeviceKey, counter: number): Promise<Response> {
  const value: string = await challenge(harness, session, "assert");
  const assertion = await createAssertion(device, "meetings.start", value, counter, validAttestationOptions());
  return harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: { device: assertion } }));
}

describe("App Attest onayı (attestation)", () => {
  it("Apple biçimindeki geçerli onay cihazı kaydeder", async () => {
    const harness: Harness = await createHarness(authority.rootPem);
    const session: Session = await signIn(harness);
    const device: DeviceKey = await createDeviceKey();
    const response: Response = await attest(harness, session, device, validAttestationOptions());
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ deviceId: device.keyIdBase64 });
    const row = await env.DB.prepare("SELECT sign_count, validation_category, bundle_version FROM devices WHERE id = ?")
      .bind(device.keyIdBase64)
      .first<{ sign_count: number; validation_category: number; bundle_version: string }>();
    expect(row).toEqual({ sign_count: 0, validation_category: 6, bundle_version: "0.2.0" });
  });

  it("aynı anahtar ikinci kez kaydedilemez, meydan okuma tek kullanımlıktır", async () => {
    const harness: Harness = await createHarness(authority.rootPem);
    const session: Session = await signIn(harness);
    const device: DeviceKey = await createDeviceKey();
    const value: string = await challenge(harness, session, "attest");
    const attestation: string = await createAttestation(authority, device, value, validAttestationOptions());
    const body = { keyId: device.keyIdBase64, attestation, challenge: value };
    expect((await harness.call(req("POST", "/v1/device/attest", { token: session.accessToken, json: body }))).status).toBe(201);
    await expectError(await harness.call(req("POST", "/v1/device/attest", { token: session.accessToken, json: body })), 400, "challenge_invalid");
    await expectError(await attest(harness, session, device, validAttestationOptions()), 400, "attestation_invalid");
  });

  it("yanlış App ID, üretim aaguid'i, izinsiz kategori, sıfır olmayan sayaç ve yanlış aclBlob reddedilir", async () => {
    const harness: Harness = await createHarness(authority.rootPem);
    const session: Session = await signIn(harness);
    const cases: AttestationOptions[] = [
      { ...validAttestationOptions(), appId: "TEAMID0000.com.baskasi.app" },
      { ...validAttestationOptions(), aaguid: productionAaguid },
      { ...validAttestationOptions(), validationCategory: 10 },
      { ...validAttestationOptions(), counter: 1 },
      { ...validAttestationOptions(), aclBlob: utf8("baska-politika") },
    ];
    for (const options of cases) {
      await expectError(await attest(harness, session, await createDeviceKey(), options), 400, "attestation_invalid");
    }
  });

  it("başka bir meydan okumayla üretilmiş onay (nonce uyuşmazlığı) reddedilir", async () => {
    const harness: Harness = await createHarness(authority.rootPem);
    const session: Session = await signIn(harness);
    const device: DeviceKey = await createDeviceKey();
    const value: string = await challenge(harness, session, "attest");
    const attestation: string = await createAttestation(authority, device, "baska-meydan-okuma-0123456789", validAttestationOptions());
    await expectError(
      await harness.call(req("POST", "/v1/device/attest", { token: session.accessToken, json: { keyId: device.keyIdBase64, attestation, challenge: value } })),
      400,
      "attestation_invalid",
    );
  });

  it("gerçek Apple kökü sahte zinciri kabul etmez", async () => {
    const device: DeviceKey = await createDeviceKey();
    const attestation: string = await createAttestation(authority, device, "meydan-okuma-0123456789", validAttestationOptions());
    const { base64Decode } = await import("../src/crypto");
    await expect(
      verifyAttestation(base64Decode(attestation), device.keyId, utf8("meydan-okuma-0123456789"), {
        appIds: [testAppId],
        environment: "development",
        allowedCategories: [6],
        rootPem: appleAppAttestationRootPem,
        now: new Date(Date.UTC(2026, 5, 1)),
      }),
    ).rejects.toThrow("Sertifika zinciri Apple köküne bağlanmıyor");
  });
});

describe("App Attest onayı (assertion) ve cihaz başına deneme", () => {
  it("geçerli onayla toplantı başlar; aynı sayaçla yeniden oynatma reddedilir", async () => {
    const harness: Harness = await createHarness(authority.rootPem);
    const session: Session = await signIn(harness);
    const device: DeviceKey = await createDeviceKey();
    expect((await attest(harness, session, device, validAttestationOptions())).status).toBe(201);

    const started: Response = await startWithDevice(harness, session, device, 1);
    expect(started.status).toBe(201);
    const meeting = await env.DB.prepare("SELECT device_id FROM meeting_sessions WHERE id = ?")
      .bind((await started.json<StartedMeetingBody>()).meetingId)
      .first<{ device_id: string }>();
    expect(meeting?.device_id).toBe(device.keyIdBase64);

    await expectError(await startWithDevice(harness, session, device, 1), 403, "assertion_invalid");
    expect((await startWithDevice(harness, session, device, 2)).status).toBe(201);
  });

  it("başka eylem için üretilmiş onay ve başka anahtarın imzası reddedilir", async () => {
    const harness: Harness = await createHarness(authority.rootPem);
    const session: Session = await signIn(harness);
    const device: DeviceKey = await createDeviceKey();
    await attest(harness, session, device, validAttestationOptions());

    const value: string = await challenge(harness, session, "assert");
    const wrongAction = await createAssertion(device, "billing.checkout", value, 1, validAttestationOptions());
    await expectError(await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: { device: wrongAction } })), 403, "assertion_invalid");

    const other: DeviceKey = await createDeviceKey();
    const forged = await createAssertion(other, "meetings.start", await challenge(harness, session, "assert"), 1, validAttestationOptions());
    await expectError(
      await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: { device: { ...forged, keyId: device.keyIdBase64 } } })),
      403,
      "assertion_invalid",
    );
  });

  it("yeni hesap aynı cihazda yeni deneme hakkı almaz", async () => {
    const harness: Harness = await createHarness(authority.rootPem);
    const first: Session = await signIn(harness);
    const device: DeviceKey = await createDeviceKey();
    await attest(harness, first, device, validAttestationOptions());
    let counter: number = 0;
    for (let index: number = 0; index < 3; index += 1) {
      counter += 1;
      expect((await startWithDevice(harness, first, device, counter)).status).toBe(201);
    }
    await expectError(await startWithDevice(harness, first, device, ++counter), 402, "trial_exhausted");

    const second: Session = await signIn(harness);
    await expectError(await startWithDevice(harness, second, device, ++counter), 402, "trial_exhausted");
    const me = await (await harness.call(req("GET", "/v1/me", { token: second.accessToken }))).json<{ trialMeetingsLeft: number }>();
    expect(me.trialMeetingsLeft).toBe(3);
  });

  it("zorunlu politikada cihaz onayı olmadan toplantı başlamaz", async () => {
    const harness: Harness = await createHarness(authority.rootPem);
    const session: Session = await signIn(harness);
    const required = envWith({ APP_ATTEST_POLICY: "required" });
    await expectError(
      await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: required })),
      403,
      "attestation_required",
    );
  });
});

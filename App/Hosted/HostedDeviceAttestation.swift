import AINotepadCore
import CryptoKit
import DeviceCheck
import Foundation
import os

private let attestLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedAttest")

/// Doğrulanmış App Attest anahtarının kimliği (base64; gizli değildir, anahtarın kendisi Secure Enclave'dedir).
private let attestKeyDefaultsKey: String = "hosted.appAttestKeyID"

/// Onayın istemci verisi: `{"action": …, "challenge": …}` (sunucu imzayı SHA256(authData || SHA256(bu bayt)) üzerinde
/// doğrular ve meydan okumayı tek seferlik tüketir).
private struct AssertionClientData: Encodable {
    let action: String
    let challenge: String
}

/// Apple App Attest (DeviceCheck) bağlantısı: cihaz anahtarı bir kez sunucuya doğrulatılır, toplantı başlatırken onay
/// eklenir. Sunucu politikası isteğe bağlıdır: `isSupported` yanlışsa (bugün macOS'ta öyle) ya da adımlardan biri
/// başarısızsa uyarı loglanır ve onaysız devam edilir; deneme hakkı yine hesap başına sayılır.
enum HostedDeviceAttestation {
    /// Cihaz anahtarı yoksa üretip doğrulatır; varsa `/v1/me` için bağlantıya bildirir.
    static func prepare(client: HostedClient) async {
        guard DCAppAttestService.shared.isSupported else {
            return
        }
        if let keyID = UserDefaults.standard.string(forKey: attestKeyDefaultsKey) {
            await client.setDeviceKeyID(keyID: keyID)
            return
        }
        do {
            let keyID: String = try await DCAppAttestService.shared.generateKey()
            let challenge: HostedDeviceChallenge = try await client.deviceChallenge(purpose: "attest")
            let clientDataHash: Data = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
            let attestation: Data = try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
            try await client.attestDevice(keyID: keyID, attestation: attestation.base64EncodedString(), challenge: challenge.challenge)
            UserDefaults.standard.set(keyID, forKey: attestKeyDefaultsKey)
            await client.setDeviceKeyID(keyID: keyID)
            attestLogger.info("Cihaz doğrulandı (App Attest)")
        } catch {
            attestLogger.warning("Cihaz doğrulanamadı, onaysız devam ediliyor, hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Hassas istek için onay; App Attest yoksa, cihaz doğrulanmamışsa ya da onay üretilemezse nil (uyarı loglanır).
    static func assertion(client: HostedClient, action: String) async -> HostedDeviceAssertion? {
        guard DCAppAttestService.shared.isSupported, let keyID = UserDefaults.standard.string(forKey: attestKeyDefaultsKey) else {
            return nil
        }
        do {
            let challenge: HostedDeviceChallenge = try await client.deviceChallenge(purpose: "assert")
            let clientData: Data = try JSONEncoder().encode(AssertionClientData(action: action, challenge: challenge.challenge))
            let assertion: Data = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: clientData)))
            return HostedDeviceAssertion(keyId: keyID, assertion: assertion.base64EncodedString(), clientData: clientData.base64EncodedString())
        } catch let error as DCError where error.code == .invalidKey {
            // Anahtar geçersizleşti (ör. sistem yeniden kuruldu): bir sonraki açılışta yenisi doğrulanır.
            UserDefaults.standard.removeObject(forKey: attestKeyDefaultsKey)
            attestLogger.warning("Cihaz anahtarı geçersiz, silindi; onaysız devam ediliyor")
            return nil
        } catch {
            attestLogger.warning("Cihaz onayı üretilemedi, onaysız devam ediliyor, hata: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}

/// Apple DeviceCheck jetonu: sunucu bununla Apple'da bu Mac'in iki bitini okur ve yazar (`bit0` = "bu Mac bir hesaba
/// ücretsiz deneme verdi"); Apple sunucuya cihaz kimliği vermez. App Attest'in aksine macOS'ta çalışır. Jeton kısa
/// ömürlüdür, her deneme toplantısı başlatmada yeniden üretilir ve loglanmaz.
@MainActor
enum HostedDeviceCheck {
    /// Bu açılışta son jeton üretiminin hatası (Tanılama'da hata kodu görünür; jeton yazılmaz); başarıda nil.
    private(set) static var lastFailure: String?

    /// Jetonu base64 olarak üretir; DeviceCheck desteklenmiyorsa ya da üretilemezse `HostedDeviceCheckError`.
    static func token() async throws -> String {
        guard DCDevice.current.isSupported else {
            attestLogger.error("DeviceCheck desteklenmiyor")
            lastFailure = "unsupported"
            throw HostedDeviceCheckError.unsupported
        }
        do {
            let token: String = try await DCDevice.current.generateToken().base64EncodedString()
            lastFailure = nil
            return token
        } catch {
            // Hata kodu (alan ve sayı) gizli değildir; imzalı sürümde neyin ters gittiğini anlamak için açık loglanır.
            let code: String = deviceCheckErrorCode(error: error)
            attestLogger.error("DeviceCheck jetonu üretilemedi, kod: \(code, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            lastFailure = code
            throw HostedDeviceCheckError.tokenFailed(reason: code)
        }
    }
}

/// Hatanın alanı ve kodu, ör. "com.apple.devicecheck.error 2". Saf fonksiyondur.
func deviceCheckErrorCode(error: any Error) -> String {
    let nsError: NSError = error as NSError
    return "\(nsError.domain) \(nsError.code)"
}

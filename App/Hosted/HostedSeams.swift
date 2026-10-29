import AINotepadCore
import Foundation

// Abonelik sürümünün paylaşılan koda bağlandığı noktalar (`#if HOSTED_EDITION` ile çağrılır): LLM sağlayıcısı, son
// geçiş, kurulum eksikleri, canlı metin motoru ve rapor hedefi.

/// Abonelik sürümünde canlı metin her zaman Mac'te (WhisperKit, ücretsiz); motor seçimi gizlidir.
let hostedLiveEngine: LiveEngine = .whisperKit

/// Kayıt sırasındaki ve kaydın hemen ardındaki yapay zekâ çağrıları: son açılan toplantının bütçesinden düşer.
func hostedMeetingLLMProvider() throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .meeting))
}

/// Her zaman kullanılabilen yapay zekâ çağrıları (Sor, notu yeniden yazma, düzenleme, paylaşım çevirisi, görev aracı):
/// toplantı kimliği gönderilmez, kullanıcının sınırlarına sayılır.
func hostedAccountLLMProvider() throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .account))
}

/// Son geçiş: kayıt sunucunun `/v1/transcribe` ucuyla (ElevenLabs Scribe) yazıya dökülür; toplantı oturumu yoksa
/// (ör. ek süre geçtikten sonra "Tekrar işle") atlanır, nedeni toplantıda görünür.
func hostedFinalPassPlan(keyterms: [String]) async -> FinalPassPlan {
    let client: HostedClient
    do {
        client = try HostedServices.requireClient()
    } catch {
        return .skip(reason: userFacingMessage(error: error))
    }
    guard let meetingID = await client.currentMeetingID() else {
        return .skip(reason: userFacingMessage(error: HostedClientError.noActiveMeeting))
    }
    return .run(HostedFinalTranscriber(client: client, meetingID: meetingID, keyterms: keyterms))
}

/// Kurulum eksikleri (menüde ve Ana sayfada): sunucu adresi geçersizse ya da giriş yapılmamışsa.
func hostedSetupProblems() async -> [String] {
    do {
        guard try await HostedServices.requireClient().isSignedIn() else {
            return [userFacingMessage(error: HostedClientError.notSignedIn)]
        }
        return []
    } catch {
        return [userFacingMessage(error: error)]
    }
}

/// Geri bildirim ve çökme raporunun hedefi: abonelik sunucusu; giriş yapılmışsa rapor hesaba bağlanır (bearer).
func hostedReportDestination() async throws -> ReportDestination {
    let client: HostedClient = try HostedServices.requireClient()
    let accessToken: String? = try await client.isSignedIn() ? try await client.validAccessToken() : nil
    return ReportDestination(baseURL: client.baseURL, accessToken: accessToken)
}

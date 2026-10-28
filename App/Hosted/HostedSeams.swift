import AINotepadCore
import Foundation

// Abonelik sürümünün paylaşılan koda bağlandığı noktalar (`#if HOSTED_EDITION` ile çağrılır): LLM sağlayıcısı, son
// geçiş, kurulum eksikleri ve canlı metin motoru.

/// Abonelik sürümünde canlı metin her zaman Mac'te (WhisperKit, ücretsiz); motor seçimi gizlidir.
let hostedLiveEngine: LiveEngine = .whisperKit

/// Yapay zekâ sağlayıcısı: bizim sunucumuz (Claude Haiku 5.5 vekili). Jeton ve toplantı her çağrıda bağlantıdan alınır.
func hostedLLMProvider() throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client))
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

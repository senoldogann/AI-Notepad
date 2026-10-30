import Foundation

/// Seçili LLM sağlayıcısı türü (Ayarlar'da saklanır).
public enum LLMProviderKind: String, Sendable, CaseIterable {
    case anthropic
    case openAICompatible
    /// Apple Intelligence (cihaz içi, anahtarsız).
    case onDevice
}

/// Bu bilgisayarı gösteren ana bilgisayar adları (şifresiz http'ye yalnızca bunlarda izin verilir).
let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

/// Kullanıcının OpenAI uyumlu sağlayıcı ayarlarından yapılandırma üretir; adres ya da model eksik/geçersizse
/// `notConfigured`. Saf fonksiyondur.
public func openAICompatibleConfig(
    baseURLText: String, apiKey: String?, fastModel: String, smartModel: String, fastEffort: LLMEffort?, smartEffort: LLMEffort?
) throws -> OpenAICompatibleConfig {
    let trimmed: String = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host() else {
        throw LLMError.notConfigured(detail: String(localized: "geçerli bir temel adres (ör. http://localhost:11434/v1)"))
    }
    // Şifresiz http yalnızca bu bilgisayar için: ağdaki bir adrese anahtar ve toplantı metni açık gitmesin.
    guard scheme == "https" || loopbackHosts.contains(host.lowercased()) else {
        throw LLMError.notConfigured(detail: String(localized: "https adresi (http yalnızca bu bilgisayardaki sunucu için: localhost, 127.0.0.1)"))
    }
    let fast: String = fastModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let smart: String = smartModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fast.isEmpty, !smart.isEmpty else {
        throw LLMError.notConfigured(detail: String(localized: "çeviri ve özet modeli adları"))
    }
    return OpenAICompatibleConfig(
        baseURL: url, apiKey: apiKey.flatMap { $0.isEmpty ? nil : $0 }, fastModel: fast, smartModel: smart,
        fastEffort: fastEffort, smartEffort: smartEffort
    )
}


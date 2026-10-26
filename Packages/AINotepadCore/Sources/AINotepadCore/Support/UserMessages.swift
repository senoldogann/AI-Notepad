import Foundation

/// Hataları kullanıcıya gösterilecek, ne yapılacağını söyleyen Türkçe metne çevirir (anahtar ve toplantı metni içermez).
/// Saf fonksiyondur.
public func userFacingMessage(error: any Error) -> String {
    switch error {
    case KeychainError.notFound(_, let account):
        return "\(serviceName(account: account)) anahtarı kayıtlı değil. Menüden Ayarlar…'ı açıp ekle."
    case KeychainError.unexpectedStatus(let operation, let status):
        return "Anahtar Keychain'den okunamadı (\(operation), kod \(status))."
    case LLMError.http(let status, _) where status == 401 || status == 403:
        return "Anthropic anahtarı geçersiz (HTTP \(status)). Ayarlar'dan kontrol et."
    case LLMError.http(let status, _):
        return "Claude isteği başarısız (HTTP \(status)). Biraz sonra \"Tekrar işle\"yi dene."
    case LLMError.refusal:
        return "Claude bu isteği yanıtlamadı (güvenlik denetimi)."
    case LLMError.malformed, LLMError.empty, LLMError.invalidSchema:
        return "Claude'dan beklenmeyen yanıt geldi. \"Tekrar işle\"yi dene."
    case CloudSTTError.http(let service, let status, _) where status == 401 || status == 403:
        return "\(serviceDisplayName(service: service)) anahtarı geçersiz (HTTP \(status)). Ayarlar'dan kontrol et."
    case CloudSTTError.http(let service, let status, _):
        return "\(serviceDisplayName(service: service)) isteği başarısız (HTTP \(status)). Biraz sonra \"Tekrar işle\"yi dene."
    case CloudSTTError.malformedMessage(let service, _):
        return "\(serviceDisplayName(service: service)) beklenmeyen bir yanıt verdi."
    case CloudSTTError.connectionFailed(let service, _):
        return "\(serviceDisplayName(service: service)) servisine bağlanılamadı; internet bağlantını kontrol et."
    case AudioCaptureError.recorderFailed(let path, _):
        return "Ses dosyası işlenemedi: \((path as NSString).lastPathComponent)."
    case let urlError as URLError:
        return "Ağ hatası (\(urlError.code.rawValue)); internet bağlantını kontrol et ve tekrar dene."
    default:
        return "Beklenmeyen hata: \(String(describing: type(of: error)))."
    }
}

private func serviceName(account: String) -> String {
    switch account {
    case SecretAccount.deepgram.rawValue: "Deepgram"
    case SecretAccount.elevenlabs.rawValue: "ElevenLabs"
    default: "Anthropic"
    }
}

private func serviceDisplayName(service: String) -> String {
    switch service {
    case "elevenlabs": "ElevenLabs"
    case "deepgram": "Deepgram"
    default: service
    }
}

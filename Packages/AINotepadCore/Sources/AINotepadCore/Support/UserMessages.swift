import Foundation

/// Hataları kullanıcıya gösterilecek, ne yapılacağını söyleyen Türkçe metne çevirir (anahtar ve toplantı metni içermez).
/// Panel, ada, menü ve Toplantılar penceresindeki tüm hata metinleri buradan geçer. Saf fonksiyondur.
public func userFacingMessage(error: any Error) -> String {
    switch error {
    case let error as AudioCaptureError:
        return audioMessage(error: error)
    case let error as KeychainError:
        return keychainMessage(error: error)
    case let error as LLMError:
        return llmMessage(error: error)
    case let error as CloudSTTError:
        return cloudMessage(error: error)
    case let error as StorageError:
        return storageMessage(error: error)
    case TranscriptionError.modelLoadFailed(let model, _):
        return "Konuşma tanıma modeli (\(model)) yüklenemedi. İnternet bağlantını ve disk alanını kontrol edip uygulamayı yeniden aç."
    case TranscriptionError.transcriptionFailed:
        return "Bu bölüm yazıya dökülemedi."
    case TranscriptionError.diarizationFailed:
        return "Konuşmacı ayırma modeli çalışmadı (ilk kullanımda internet gerekir)"
    case let urlError as URLError:
        return "Ağ hatası (\(urlError.code.rawValue)); internet bağlantını kontrol et ve tekrar dene."
    default:
        return "Beklenmeyen hata: \(String(describing: type(of: error)))."
    }
}

/// ElevenLabs kota dolunca da 401 döner; gövdedeki `quota_exceeded` ayırt eder. Saf fonksiyondur.
public func isQuotaExceeded(body: String) -> Bool {
    body.contains("quota_exceeded")
}

private func audioMessage(error: AudioCaptureError) -> String {
    switch error {
    case .microphonePermissionDenied:
        "Mikrofon izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon'dan AI-Notepad'e izin ver."
    case .microphoneStartFailed(let code):
        "Mikrofon başlatılamadı (kod \(code)). Giriş cihazını kontrol edip kaydı yeniden başlat."
    case .systemAudioPermissionDenied:
        "Sistem sesi kaydı izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi Kaydı'ndan AI-Notepad'e izin ver."
    case .coreAudio(let operation, let status):
        "Sistem sesi yakalanamadı (\(operation), kod \(status)). Çıkış cihazını kontrol edip kaydı yeniden başlat."
    case .alreadyRunning:
        "Ses yakalama zaten çalışıyor."
    case .converterCreationFailed, .conversionFailed:
        "Ses biçimi dönüştürülemedi. Çıkış/giriş cihazını değiştirip kaydı yeniden başlat."
    case .recorderFailed(let path, _):
        "Ses dosyası işlenemedi: \((path as NSString).lastPathComponent). Disk alanını kontrol et."
    }
}

private func keychainMessage(error: KeychainError) -> String {
    switch error {
    case .notFound(_, let account):
        "\(serviceName(account: account)) anahtarı kayıtlı değil. Menüden Ayarlar…'ı açıp ekle."
    case .unexpectedStatus(let operation, let status):
        "Anahtar Keychain'den okunamadı (\(operation), kod \(status)). İzin penceresinde \"Her Zaman İzin Ver\"i seç."
    }
}

private func llmMessage(error: LLMError) -> String {
    switch error {
    case .http(let status, _, let model, _) where status == 401 || status == 403:
        "\(providerName(model: model)) anahtarı geçersiz (HTTP \(status)). Ayarlar'dan kontrol et."
    case .http(let status, _, let model, _):
        "\(providerName(model: model)) isteği başarısız (HTTP \(status)). Biraz sonra tekrar dene."
    case .truncated:
        "Yanıt çok uzun olduğu için yarıda kesildi. Tekrar dene."
    case .refusal:
        "Model bu isteği yanıtlamadı (güvenlik denetimi)."
    case .malformed, .empty, .invalidSchema:
        "Modelden beklenmeyen yanıt geldi. Tekrar dene."
    case .notConfigured(let detail):
        "LLM ayarı eksik: \(detail). Ayarlar'dan tamamla."
    }
}

private func cloudMessage(error: CloudSTTError) -> String {
    switch error {
    case .http(let service, let status, let body) where status == 401 && isQuotaExceeded(body: body):
        "\(serviceDisplayName(service: service)) kotası doldu. Hesabından kota ekle ya da Ayarlar'dan Mac'te motorunu seç."
    case .http(let service, let status, _) where status == 401 || status == 403:
        "\(serviceDisplayName(service: service)) anahtarı geçersiz (HTTP \(status)). Ayarlar'dan kontrol et."
    case .http(let service, let status, _):
        "\(serviceDisplayName(service: service)) isteği başarısız (HTTP \(status)). Biraz sonra tekrar dene."
    case .malformedMessage(let service, _):
        "\(serviceDisplayName(service: service)) beklenmeyen bir yanıt verdi."
    case .connectionFailed(let service, _):
        "\(serviceDisplayName(service: service)) servisine bağlanılamadı; internet bağlantını kontrol et."
    }
}

private func storageMessage(error: StorageError) -> String {
    switch error {
    case .readFailed(let path, _):
        "Dosya okunamadı: \((path as NSString).lastPathComponent)."
    case .writeFailed(let path, _):
        "Dosya yazılamadı: \((path as NSString).lastPathComponent). Disk alanını kontrol et."
    case .deleteFailed(let path, _):
        "Dosya silinemedi: \((path as NSString).lastPathComponent)."
    case .directoryUnavailable(let path, _):
        "Klasöre erişilemedi: \((path as NSString).lastPathComponent)."
    }
}

/// Model adından sağlayıcı adı: Claude modelleri Anthropic, diğerleri OpenAI uyumlu sağlayıcı.
private func providerName(model: String) -> String {
    model.hasPrefix("claude-") ? "Anthropic" : "LLM"
}

private func serviceName(account: String) -> String {
    switch account {
    case SecretAccount.deepgram.rawValue: "Deepgram"
    case SecretAccount.elevenlabs.rawValue: "ElevenLabs"
    case SecretAccount.anthropic.rawValue: "Anthropic"
    default: "LLM"
    }
}

private func serviceDisplayName(service: String) -> String {
    switch service {
    case "elevenlabs": "ElevenLabs"
    case "deepgram": "Deepgram"
    default: service
    }
}

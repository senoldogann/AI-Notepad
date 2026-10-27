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
        return String(localized: "Konuşma tanıma modeli (\(model)) yüklenemedi. İnternet bağlantını ve disk alanını kontrol edip uygulamayı yeniden aç.")
    case TranscriptionError.transcriptionFailed:
        return String(localized: "Bu bölüm yazıya dökülemedi.")
    case TranscriptionError.diarizationFailed:
        return String(localized: "Konuşmacı ayırma modeli çalışmadı (ilk kullanımda internet gerekir)")
    case OllamaError.unreachable:
        return String(localized: "Ollama'ya ulaşılamadı. Ollama uygulamasının açık olduğunu ve adresin doğru olduğunu kontrol et.")
    case OllamaError.http(_, let status, _):
        return String(localized: "Ollama isteği reddetti (HTTP \(status)). Adresi ve Ollama sürümünü kontrol et.")
    case OllamaError.malformed:
        return String(localized: "Ollama'nın yanıtı anlaşılamadı. Ollama'yı güncelleyip yeniden dene.")
    case WebhookError.invalidURL:
        return String(localized: "Webhook adresi geçersiz: https:// ile başlayan tam adresi yapıştır.")
    case WebhookError.http(let host, let status, _):
        return String(localized: "\(host) webhook'u reddetti (HTTP \(status)). Adresin doğru ve etkin olduğunu kontrol et.")
    case WebhookError.network(let host, _):
        return String(localized: "\(host) adresine ulaşılamadı; internet bağlantını kontrol et.")
    case let urlError as URLError:
        return String(localized: "Ağ hatası (\(urlError.code.rawValue)); internet bağlantını kontrol et ve tekrar dene.")
    default:
        return String(localized: "Beklenmeyen hata: \(String(describing: type(of: error))).")
    }
}

/// ElevenLabs kota dolunca da 401 döner; gövdedeki `quota_exceeded` ayırt eder. Saf fonksiyondur.
public func isQuotaExceeded(body: String) -> Bool {
    body.contains("quota_exceeded")
}

private func audioMessage(error: AudioCaptureError) -> String {
    switch error {
    case .microphonePermissionDenied:
        String(localized: "Mikrofon izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon'dan AI-Notepad'e izin ver.")
    case .microphoneStartFailed(let code):
        String(localized: "Mikrofon başlatılamadı (kod \(Int(code))). Giriş cihazını kontrol edip kaydı yeniden başlat.")
    case .systemAudioPermissionDenied:
        String(localized: "Sistem sesi kaydı izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi Kaydı'ndan AI-Notepad'e izin ver.")
    case .coreAudio(let operation, let status):
        String(localized: "Sistem sesi yakalanamadı (\(operation), kod \(Int(status))). Çıkış cihazını kontrol edip kaydı yeniden başlat.")
    case .alreadyRunning:
        String(localized: "Ses yakalama zaten çalışıyor.")
    case .converterCreationFailed, .conversionFailed:
        String(localized: "Ses biçimi dönüştürülemedi. Çıkış/giriş cihazını değiştirip kaydı yeniden başlat.")
    case .recorderFailed(let path, _):
        String(localized: "Ses dosyası işlenemedi: \((path as NSString).lastPathComponent). Disk alanını kontrol et.")
    }
}

private func keychainMessage(error: KeychainError) -> String {
    switch error {
    case .notFound(_, let account):
        String(localized: "\(serviceName(account: account)) anahtarı kayıtlı değil. Ayarlar'dan ekle.")
    case .unexpectedStatus(let operation, let status):
        String(localized: "Anahtar Keychain'den okunamadı (\(operation), kod \(Int(status))). İzin penceresinde \"Her Zaman İzin Ver\"i seç.")
    }
}

private func llmMessage(error: LLMError) -> String {
    switch error {
    case .http(let status, _, let model, _) where status == 401 || status == 403:
        String(localized: "\(providerName(model: model)) anahtarı geçersiz (HTTP \(status)). Ayarlar'dan kontrol et.")
    case .http(let status, _, let model, _):
        String(localized: "\(providerName(model: model)) isteği başarısız (HTTP \(status)). Biraz sonra tekrar dene.")
    case .truncated(let model):
        // Düşünme de çıktı sınırından harcar: aynı ayarla tekrar denemek aynı sonucu verir.
        String(localized: "\(model) yanıtı çıktı sınırına ulaştığı için yarıda kesildi. Ayarlar › LLM'de effort'u düşürüp tekrar dene.")
    case .streamFailed(let errorType, _, let model):
        String(localized: "\(providerName(model: model)) yanıtı yarıda hata verdi (\(errorType)). Biraz sonra tekrar dene.")
    case .refusal:
        String(localized: "Model bu isteği yanıtlamadı (güvenlik denetimi).")
    case .malformed, .empty, .invalidSchema:
        String(localized: "Modelden beklenmeyen yanıt geldi. Tekrar dene.")
    case .notConfigured(let detail):
        String(localized: "LLM ayarı eksik: \(detail). Ayarlar'dan tamamla.")
    }
}

private func cloudMessage(error: CloudSTTError) -> String {
    switch error {
    case .http(let service, let status, let body) where status == 401 && isQuotaExceeded(body: body):
        String(localized: "\(serviceDisplayName(service: service)) kotası doldu. Hesabından kota ekle ya da Ayarlar'dan Mac'te motorunu seç.")
    case .http(let service, let status, _) where status == 401 || status == 403:
        String(localized: "\(serviceDisplayName(service: service)) anahtarı geçersiz (HTTP \(status)). Ayarlar'dan kontrol et.")
    case .http(let service, let status, _):
        String(localized: "\(serviceDisplayName(service: service)) isteği başarısız (HTTP \(status)). Biraz sonra tekrar dene.")
    case .malformedMessage(let service, _):
        String(localized: "\(serviceDisplayName(service: service)) beklenmeyen bir yanıt verdi.")
    case .connectionFailed(let service, _):
        String(localized: "\(serviceDisplayName(service: service)) servisine bağlanılamadı; internet bağlantını kontrol et.")
    }
}

private func storageMessage(error: StorageError) -> String {
    switch error {
    case .readFailed(let path, _):
        String(localized: "Dosya okunamadı: \((path as NSString).lastPathComponent).")
    case .writeFailed(let path, _):
        String(localized: "Dosya yazılamadı: \((path as NSString).lastPathComponent). Disk alanını kontrol et.")
    case .deleteFailed(let path, _):
        String(localized: "Dosya silinemedi: \((path as NSString).lastPathComponent).")
    case .directoryUnavailable(let path, _):
        String(localized: "Klasöre erişilemedi: \((path as NSString).lastPathComponent).")
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
    case SecretAccount.webhook.rawValue: "Webhook"
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

import Foundation
import Security

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
    case let error as HostedAPIError:
        return hostedErrorMessage(error: error)
    case let error as HostedClientError:
        return hostedClientMessage(error: error)
    case let error as HostedDeviceCheckError:
        return hostedDeviceCheckMessage(error: error)
    case let error as HostedBrowserSignInError:
        return hostedBrowserSignInMessage(error: error)
    case let error as OnDeviceLLMError:
        return onDeviceMessage(error: error)
    case let error as AppleSpeechError:
        return appleSpeechMessage(error: error)
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
    case OllamaError.http:
        return String(localized: "Ollama isteği reddetti. Adresi ve Ollama sürümünü kontrol edip yeniden dene.")
    case OllamaError.malformed:
        return String(localized: "Ollama'nın yanıtı anlaşılamadı. Ollama'yı güncelleyip yeniden dene.")
    case ArchiveScopeError.meetingsNotFound:
        return String(localized: "Etiketlenen toplantılardan biri artık yok (silinmiş ya da taşınmış); etiketleri kaldırıp yeniden seç.")
    case NoteHistoryError.versionNotFound:
        return String(localized: "Bu not sürümü artık geçmişte yok; menüyü yeniden açıp tekrar seç.")
    case AudioClipError.noAudio:
        return String(localized: "Bu an için ses yok (kayıt silinmiş ya da bu bölümde ses kaydedilmemiş).")
    case AudioClipError.exportFailed(_, let reason):
        return String(localized: "Klip kaydedilemedi: \(reason)")
    case WebhookError.invalidURL:
        return String(localized: "Webhook adresi geçersiz: https:// ile başlayan tam adresi yapıştır.")
    case WebhookError.http(let host, _, _):
        return String(localized: "\(host) webhook'u kabul etmedi. Adresin doğru ve etkin olduğunu kontrol et.")
    case WebhookError.network(let host, _):
        return String(localized: "\(host) adresine ulaşılamadı; internet bağlantını kontrol et.")
    case let error as ChannelAuthError:
        return channelMessage(error: error)
    case let error as MCPRemoteError:
        return mcpRemoteMessage(error: error)
    case SkillImportError.missingFrontMatter(let file):
        return String(localized: "\(file) bir Agent Skill değil: başta name ve description içeren --- bölümü yok.")
    case SkillImportError.emptyBody(let file):
        return String(localized: "\(file) boş: yönerge yok.")
    case DestinationError.notFound:
        return String(localized: "Bu bağlantı artık yok (kaldırılmış); Ayarlar › Bağlantılar'ı yeniden aç.")
    case DestinationError.notAnAccount:
        return String(localized: "Bu bağlantıda kanal seçilmez.")
    case TaskTrackerError.partial(let service, let created, let total, let reason):
        return String(localized: "\(service): \(created.count)/\(total) görev açıldı; kalanlar açılamadı: \(reason). Yeniden gönderince yalnızca kalanlar gider.")
    case TaskTrackerError.noCreateTool(let service):
        return String(localized: "\(service) bağlantısında iş açan araç bulunamadı; sunucunun araçları değişmiş olabilir. Uygulamayı güncelle ya da yeniden bağlan.")
    case TaskTrackerError.notFound:
        return String(localized: "Bu görev aracı artık yok (kaldırılmış); Ayarlar › Bağlantılar'ı yeniden aç.")
    case TaskTrackerError.uncertain(let service, let created, _, let taskTitle, let total, let reason):
        return String(localized: "\(service): \(created.count)/\(total) görev açıldı. «\(taskTitle)» açılırken yanıt gelmedi (\(reason)); iş açılmış olabilir. Yeniden göndermeden önce \(service) içinde kontrol et: açıldıysa yeniden gönderim onu ikinci kez açar.")
    case NoteSendError.meetingNotFound:
        return String(localized: "Bu toplantı artık yok (silinmiş ya da taşınmış); listeyi yenileyip yeniden dene.")
    case NoteSendError.noNote:
        return String(localized: "Bu toplantının notu yok; önce notu oluştur.")
    case NoteSendError.alreadySending:
        return String(localized: "Bu not bu bağlantıya zaten gönderiliyor; bitmesini bekle.")
    case let error as DeliveryUncertainError:
        return String(localized: "\(error.host) yanıt vermedi (\(error.reason)); not gitmiş olabilir. Kontrol et, gitmediyse elle yeniden gönder. Kendiliğinden yeniden gönderilmeyecek.")
    case MCPConfigError.invalidConfig(let path, _):
        return String(localized: "Uygulamanın yapılandırması okunamadı (\((path as NSString).lastPathComponent)); bozuk olabilir. Dosyayı düzeltip yeniden dene; üzerine yazılmadı.")
    case MCPConfigError.hasComments(let path):
        return String(localized: "\((path as NSString).lastPathComponent) yorum satırları içeriyor; yorumlar kaybolmasın diye üzerine yazılmadı. Toplantı sunucusunu o uygulamanın ayarından elle ekle (komut: bu uygulama, --mcp argümanıyla).")
    case MCPConfigError.translocated:
        return String(localized: "Uygulama geçici bir konumdan çalışıyor. Uygulamalar klasörüne taşıyıp yeniden aç, sonra yeniden bağla.")
    case MCPConfigError.writeFailed(let path, _):
        return String(localized: "Yapılandırma yazılamadı: \((path as NSString).lastPathComponent). Klasör izinlerini kontrol et.")
    case let error as ReportError:
        return reportErrorMessage(error: error)
    case let urlError as URLError where urlError.code == .appTransportSecurityRequiresSecureConnection:
        return String(localized: "Adres şifresiz (http); güvenlik gereği bağlanılmadı. https adresi kullan.")
    case let urlError as URLError:
        return String(localized: "Ağ hatası (\(urlError.code.rawValue)); internet bağlantını kontrol et ve tekrar dene.")
    default:
        return String(localized: "Beklenmeyen hata: \(String(describing: type(of: error))).")
    }
}

private func channelMessage(error: ChannelAuthError) -> String {
    switch error {
    case .notConfigured(let service):
        String(localized: "\(service.displayName) girişi bu sürümde henüz etkin değil. Şimdilik \"Webhook adresi\" kartıyla bağlayabilirsin.")
    case .denied(.teams, let reason) where reason.contains("AADSTS90094") || reason.contains("AADSTS65001") || reason.localizedCaseInsensitiveContains("admin"):
        String(localized: "Kurumunun Microsoft hesabında bu bağlantı için yönetici onayı gerekiyor. BT yöneticine sorabilir ya da Teams'te kanal › ⋯ › İş akışları'ndan aldığın webhook adresini \"Webhook adresi\" kartına yapıştırabilirsin.")
    case .denied(let service, _):
        String(localized: "\(service.displayName) girişi tamamlanmadı (izin verilmedi). Yeniden dene.")
    case .stateMismatch(let service):
        String(localized: "\(service.displayName) girişi başka bir denemeden döndü; yeniden dene.")
    case .http(let service, _, _):
        String(localized: "\(service.displayName) isteği kabul etmedi. Yeniden dene; sürerse bağlantıyı kaldırıp yeniden bağlan.")
    case .api(.slack, "not_in_channel"), .api(.slack, "channel_not_found"):
        String(localized: "Slack kanalına yazılamadı: kanalın üyesi değilsin ya da kanal silinmiş. Ayarlar › Bağlantılar'dan başka bir kanal seç.")
    case .api(let service, _):
        String(localized: "\(service.displayName) isteği kabul etmedi. Yeniden dene; sürerse bağlantıyı kaldırıp yeniden bağlan.")
    case .network(let service, _):
        String(localized: "\(service.displayName) adresine ulaşılamadı; internet bağlantını kontrol et.")
    case .invalidResponse(let service, _):
        String(localized: "\(service.displayName) yanıtı anlaşılamadı; yeniden dene.")
    case .expired(let service):
        String(localized: "\(service.displayName) oturumunun süresi doldu. Ayarlar › Bağlantılar'dan yeniden bağlan.")
    case .noChannels(let service):
        String(localized: "\(service.displayName) hesabında yazabileceğin bir kanal bulunamadı. Önce bir kanala katıl, sonra yeniden bağlan.")
    }
}

private func mcpRemoteMessage(error: MCPRemoteError) -> String {
    switch error {
    case .noAuthorizationMetadata(let server), .noDynamicRegistration(let server):
        String(localized: "\(server) tek tıkla girişi desteklemiyor.")
    case .http(let server, _, _):
        String(localized: "\(server) isteği kabul etmedi. Yeniden dene; sürerse bağlantıyı kaldırıp yeniden bağlan.")
    case .network(let server, _):
        String(localized: "\(server) adresine ulaşılamadı; internet bağlantını kontrol et.")
    case .invalidResponse(let server, _), .rpc(let server, _, _):
        String(localized: "\(server) yanıtı anlaşılamadı; yeniden dene.")
    case .toolFailed(let server, let tool, let message):
        String(localized: "\(server) işlemi yapamadı (\(tool)): \(message)")
    case .toolMissing(let server, let tool):
        String(localized: "\(server) beklenen aracı (\(tool)) artık sunmuyor; uygulamayı güncelle.")
    case .expired(let server):
        String(localized: "\(server) oturumunun süresi doldu. Ayarlar › Bağlantılar'dan yeniden bağlan.")
    case .denied(let server, let reason):
        String(localized: "\(server) girişi tamamlanmadı: \(reason)")
    case .signInTimedOut:
        String(localized: "Tarayıcıdaki giriş süresinde tamamlanmadı; Ayarlar › Bağlantılar'dan yeniden bağlan.")
    case .foreignCallback(let server):
        String(localized: "\(server) girişinin dönüşü başka bir denemeye ait; Ayarlar › Bağlantılar'dan yeniden bağlan.")
    case .noRevocationEndpoint(let server):
        String(localized: "\(server) erişimin uygulamadan geri alınmasını desteklemiyor.")
    }
}

/// ElevenLabs kota dolunca da 401 döner; gövdedeki `quota_exceeded` ayırt eder. Saf fonksiyondur.
public func isQuotaExceeded(body: String) -> Bool {
    body.contains("quota_exceeded")
}

private func audioMessage(error: AudioCaptureError) -> String {
    switch error {
    case .microphonePermissionDenied:
        String(localized: "Mikrofon izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon'da bu uygulamaya izin ver.")
    case .microphoneStartFailed(let code):
        String(localized: "Mikrofon başlatılamadı (kod \(Int(code))). Giriş cihazını kontrol edip kaydı yeniden başlat.")
    case .coreAudio(let operation, let status):
        String(localized: "Sistem sesi yakalanamadı (\(operation), kod \(Int(status))). Çıkış cihazını kontrol edip kaydı yeniden başlat.")
    case .alreadyRunning:
        String(localized: "Ses yakalama zaten çalışıyor.")
    case .converterCreationFailed, .conversionFailed:
        String(localized: "Ses biçimi dönüştürülemedi. Çıkış/giriş cihazını değiştirip kaydı yeniden başlat.")
    case .recorderFailed(let path, _):
        String(localized: "Ses dosyası işlenemedi: \((path as NSString).lastPathComponent). Disk alanını kontrol et.")
    case .playbackSessionFailed(let code):
        String(localized: "Ses çalınamadı (kod \(Int(code))). Başka bir uygulama sesi kullanıyor olabilir; biraz sonra yeniden dene.")
    }
}

private func keychainMessage(error: KeychainError) -> String {
    switch error {
    case .notFound(_, let account):
        String(localized: "\(serviceName(account: account)) anahtarı kayıtlı değil. Ayarlar'dan ekle.")
    case .unexpectedStatus(let operation, let status):
        keychainStatusMessage(operation: operation, status: status)
    }
}

/// Keychain durum kodunun metni: Mac'te okuma izni reddedildiyse (izin penceresinde "Reddet" ya da pencere
/// gösterilemedi) "Her Zaman İzin Ver" önerilir; yazma, silme, iPhone ve diğer güvenlik işlemlerinde (rastgele sayı)
/// işlem ve kodla genel metin. Saf fonksiyondur.
private func keychainStatusMessage(operation: String, status: Int32) -> String {
    #if os(macOS)
    if operation.hasPrefix("SecItemCopyMatching"), [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed].contains(status) {
        return String(localized: "Anahtar Keychain'den okunamadı (\(operation), kod \(Int(status))). İzin penceresinde \"Her Zaman İzin Ver\"i seç.")
    }
    #endif
    return String(localized: "Güvenlik işlemi tamamlanamadı (\(operation), kod \(Int(status))). Uygulamayı yeniden açıp tekrar dene; sürerse geri bildirim gönder.")
}

private func llmMessage(error: LLMError) -> String {
    switch error {
    case .http(let status, _, let model, _) where status == 401 || status == 403:
        String(localized: "\(providerName(model: model)) anahtarı kabul edilmedi. Ayarlar'dan anahtarı kontrol et.")
    case .http(_, _, let model, _):
        String(localized: "\(providerName(model: model)) şu an yanıt veremedi. Biraz sonra yeniden dene.")
    case .truncated:
        // Düşünme de çıktı sınırından harcar: aynı ayarla tekrar denemek aynı sonucu verir.
        String(localized: "Yanıt uzunluk sınırına takılıp yarıda kesildi. İsteği kısaltıp ya da daha az toplantı seçip yeniden dene.")
    case .streamFailed(_, _, let model):
        String(localized: "\(providerName(model: model)) yanıtı yarıda kesildi. Biraz sonra yeniden dene.")
    case .refusal:
        String(localized: "Model bu isteği yanıtlamadı (güvenlik denetimi).")
    case .malformed, .empty, .invalidSchema:
        String(localized: "Modelden beklenmeyen yanıt geldi. Tekrar dene.")
    case .notConfigured(let detail):
        String(localized: "LLM ayarı eksik: \(detail). Ayarlar'dan tamamla.")
    case .hosted(let error):
        hostedErrorMessage(error: error)
    }
}

private func cloudMessage(error: CloudSTTError) -> String {
    switch error {
    case .http(let service, let status, let body) where status == 401 && isQuotaExceeded(body: body):
        String(localized: "\(serviceDisplayName(service: service)) kotası doldu. Hesabından kota ekle ya da Ayarlar'dan Mac'te motorunu seç.")
    case .http(let service, let status, _) where status == 401 || status == 403:
        String(localized: "\(serviceDisplayName(service: service)) anahtarı kabul edilmedi. Ayarlar'dan anahtarı kontrol et.")
    case .http(let service, let status, _):
        String(localized: "\(serviceDisplayName(service: service)) şu an yanıt veremedi. Biraz sonra yeniden dene.")
    case .malformedMessage(let service, _):
        String(localized: "\(serviceDisplayName(service: service)) beklenmeyen bir yanıt verdi.")
    case .connectionFailed(let service, _):
        String(localized: "\(serviceDisplayName(service: service)) servisine bağlanılamadı; internet bağlantını kontrol et.")
    }
}

/// iCloud kullanılamıyor metni: düzeltme sistemin ayarlarında (uygulamanın Ayarlar'ında değil). Saf fonksiyondur.
private func iCloudUnavailableMessage() -> String {
    #if os(macOS)
    String(localized: "iCloud kullanılamıyor. Sistem Ayarları › Apple Hesabı › iCloud'da iCloud Drive'ı aç.")
    #else
    String(localized: "iCloud kullanılamıyor. Ayarlar › Apple Hesabı › iCloud'da iCloud Drive'ı aç.")
    #endif
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
    case .iCloudUnavailable:
        iCloudUnavailableMessage()
    case .alreadyExists(let path):
        String(localized: "Aynı toplantı hedefte zaten var: \((path as NSString).lastPathComponent). İki kopyayı karşılaştırıp birini sil.")
    case .moveFailed(let path, _):
        String(localized: "Toplantı taşınamadı: \((path as NSString).lastPathComponent). İnternet bağlantısını kontrol edip yeniden dene.")
    case .dataFolderNotConfigured(let key, let bundle):
        String(localized: "Uygulamanın veri klasörü tanımlı değil (\(bundle) Info.plist'inde \(key) yok). Uygulamayı yeniden kur.")
    case .accountNotSelected:
        String(localized: "Hesabın verisi henüz açılmadı. Giriş yap.")
    case .invalidAccountKey:
        String(localized: "Hesap klasörü tanınmadı. Uygulamayı yeniden başlat; sürerse geri bildirim gönder.")
    case .accountSwitchRequiresRelaunch:
        String(localized: "Başka bir hesapla giriş yapıldı; o hesabın toplantıları için uygulama yeniden başlamalı.")
    case .legacyDataMoveFailed(let source, _, let reason, _):
        String(localized: "Önceki toplantılar hesabına taşınamadı (\((source as NSString).lastPathComponent): \(reason)). Hiçbir şey silinmedi; taşınamayanlar eski yerinde kaldı, yeniden dene.")
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
    case SecretAccount.channel.rawValue: String(localized: "Kanal bağlantısı")
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

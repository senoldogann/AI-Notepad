import AINotepadCore
import AINotepadUI
import AppKit
import AVFAudio
import CoreServices
import EventKit
import os
import SwiftUI

private let diagnosticsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Diagnostics")

/// Uygulamanın log alt sistemi (son hatalar buradan okunur).
private let appLogSubsystem: String = "com.senoldogan.AINotepad"

/// Sunucu erişim denetiminin zaman aşımı.
private let healthTimeoutSec: Double = 10

/// Apple Notlar'ın paket kimliği (Apple Events izni bunun için sorulur).
private let notesBundleID: String = "com.apple.Notes"

/// Hata mesajlarından silinecek kullanıcı adları: kısa ve tam ad.
func diagnosticsUserNames() -> [String] {
    [NSUserName(), NSFullUserName()]
}

/// Tanılamada denetlenen sunucu: abonelik sürümünde hesabın sunucusu, geliştirici sürümünde rapor sunucusu.
private func diagnosticsAPIBase() throws -> URL {
    #if HOSTED_EDITION
    try hostedDiagnosticsAPIBase()
    #else
    try anonymousReportDestination(bundle: .main).baseURL
    #endif
}

/// Uygulama bölümü: ad, sürüm, derleme, sürüm türü, sistem ve Mac modeli (seri numarası ya da donanım kimliği yok).
private func appDiagnostics(bundle: Bundle) -> DiagnosticsSection {
    let version: String = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build: String = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    #if HOSTED_EDITION
    let edition: String = String(localized: "Abonelik sürümü")
    #else
    let edition: String = String(localized: "Geliştirici sürümü")
    #endif
    let model: String
    do {
        model = try macModelIdentifier()
    } catch {
        diagnosticsLogger.error("Mac modeli okunamadı, hata: \(String(describing: error), privacy: .private)")
        model = String(localized: "okunamadı")
    }
    return DiagnosticsSection(title: String(localized: "Uygulama"), items: [
        DiagnosticsItem(label: String(localized: "Ad"), value: appName),
        DiagnosticsItem(label: String(localized: "Sürüm"), value: appVersionText(version: version, build: build)),
        DiagnosticsItem(label: String(localized: "Tür"), value: edition),
        DiagnosticsItem(label: String(localized: "Sistem"), value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"),
        DiagnosticsItem(label: String(localized: "Mac modeli"), value: model),
    ])
}

/// Sunucu bölümü: adres ve erişim denetiminin sonucu.
private func serverDiagnostics(base: Result<URL, any Error>, health: APIHealth?) -> DiagnosticsSection {
    let title: String = String(localized: "Sunucu")
    let url: URL
    switch base {
    case .success(let value):
        url = value
    case .failure(let error):
        return DiagnosticsSection(title: title, items: [
            DiagnosticsItem(label: String(localized: "Adres"), value: redactedDiagnosticText(text: userFacingMessage(error: error), userNames: diagnosticsUserNames())),
        ])
    }
    let result: String
    switch health {
    case .none:
        result = String(localized: "Denetleniyor…")
    case .reachable(let latencyMs):
        result = String(localized: "Erişilebilir, \(latencyMs) ms")
    case .unhealthy(let status, let latencyMs):
        result = String(localized: "Yanıt verdi ama sağlıklı değil (HTTP \(status)), \(latencyMs) ms")
    case .unreachable(let reason):
        result = String(localized: "Ulaşılamadı (\(reason))")
    }
    return DiagnosticsSection(title: title, items: [
        DiagnosticsItem(label: String(localized: "Adres"), value: url.host() ?? url.absoluteString),
        DiagnosticsItem(label: String(localized: "Erişim"), value: result),
    ])
}

/// Mikrofon izninin metni.
private func microphoneText(permission: AVAudioApplication.recordPermission) -> String {
    switch permission {
    case .granted: String(localized: "İzin verildi")
    case .denied: String(localized: "Reddedildi")
    case .undetermined: String(localized: "Henüz sorulmadı")
    @unknown default: String(localized: "Bilinmiyor")
    }
}

/// Takvim ya da anımsatıcı izninin metni.
private func eventKitText(status: EKAuthorizationStatus) -> String {
    switch status {
    case .fullAccess: String(localized: "Tam erişim")
    case .writeOnly: String(localized: "Yalnızca yazma")
    case .denied: String(localized: "Reddedildi")
    case .restricted: String(localized: "Kısıtlı")
    case .notDetermined: String(localized: "Henüz sorulmadı")
    @unknown default: String(localized: "Bilinmiyor")
    }
}

/// Apple Notlar'ı denetleme (Apple Events) izni; sormadan okunur (Notlar kapalıysa macOS durumu söylemez).
private func appleEventsText() -> String {
    let target: NSAppleEventDescriptor = NSAppleEventDescriptor(bundleIdentifier: notesBundleID)
    let status: OSStatus = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    switch status {
    case noErr: return String(localized: "İzin verildi")
    case OSStatus(errAEEventNotPermitted): return String(localized: "Reddedildi")
    case OSStatus(errAEEventWouldRequireUserConsent): return String(localized: "Henüz sorulmadı")
    case OSStatus(procNotFound): return String(localized: "Notlar açık değil; durum okunamıyor")
    default: return String(localized: "Bilinmiyor (\(status))")
    }
}

/// İzinler bölümü. Sistem sesi kaydı izninin durumunu macOS sorgulatmaz.
@MainActor
private func permissionDiagnostics(model: AppModel) -> DiagnosticsSection {
    DiagnosticsSection(title: String(localized: "İzinler"), items: [
        DiagnosticsItem(label: String(localized: "Mikrofon"), value: microphoneText(permission: model.microphonePermission)),
        DiagnosticsItem(label: String(localized: "Sistem sesi"), value: String(localized: "macOS bu iznin durumunu bildirmiyor; ilk kayıtta sorulur")),
        DiagnosticsItem(label: String(localized: "Takvim"), value: eventKitText(status: EKEventStore.authorizationStatus(for: .event))),
        DiagnosticsItem(label: String(localized: "Anımsatıcılar"), value: eventKitText(status: EKEventStore.authorizationStatus(for: .reminder))),
        DiagnosticsItem(label: String(localized: "Apple Notlar (Apple Events)"), value: appleEventsText()),
    ])
}

/// Canlı metin bölümü: motor ve modelin durumu.
@MainActor
private func transcriptionDiagnostics(model: AppModel) -> DiagnosticsSection {
    let status: String
    switch (model.liveEngine, model.modelStatus) {
    case (.deepgram, _):
        status = String(localized: "Bulut; model gerekmez")
    case (_, .notLoaded):
        status = String(localized: "İndirilmedi; Mac'te canlı metin gerekince indirilir")
    case (_, .loading):
        status = String(localized: "İndiriliyor ya da yükleniyor")
    case (_, .ready):
        status = String(localized: "Hazır")
    case (_, .failed(let message)):
        status = String(localized: "Başarısız: \(redactedDiagnosticText(text: message, userNames: diagnosticsUserNames()))")
    }
    #if HOSTED_EDITION
    // Abonelik: motor her kayıtta sunucuya göre seçilir (bulut ya da Mac); "Mac modeli" Mac'teki konuşma modelidir.
    return DiagnosticsSection(title: String(localized: "Canlı metin"), items: hostedLiveEngineDiagnostics(model: model, account: .shared) + [
        DiagnosticsItem(label: String(localized: "Mac modeli"), value: status),
    ])
    #else
    return DiagnosticsSection(title: String(localized: "Canlı metin"), items: [
        DiagnosticsItem(label: String(localized: "Motor"), value: model.liveEngine.rawValue),
        DiagnosticsItem(label: String(localized: "Model"), value: status),
    ])
    #endif
}

/// Güncelleme bölümü: son denetim, otomatik indirme ve bekleyen güncelleme.
@MainActor
private func updateDiagnostics(updater: AppUpdater) -> DiagnosticsSection {
    let title: String = String(localized: "Güncelleme")
    guard updater.isEnabled else {
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Durum"), value: String(localized: "Kapalı (imza anahtarı yok)"))])
    }
    let pending: String = updater.availableUpdate.map { updateHeadline(update: $0) } ?? String(localized: "Yok")
    return DiagnosticsSection(title: title, items: [
        DiagnosticsItem(label: String(localized: "Son denetim"), value: updater.lastCheckDate.map { $0.formatted(.iso8601) } ?? String(localized: "Henüz denetlenmedi")),
        DiagnosticsItem(label: String(localized: "Otomatik indirme"), value: updater.automaticallyUpdates ? String(localized: "Etkin") : String(localized: "Kapalı")),
        DiagnosticsItem(label: String(localized: "Bekleyen güncelleme"), value: pending),
    ])
}

/// Son hatalar bölümü, ekranda (en çok 50): zaman ve alan. Günlük metni geliştirici içindir (Türkçe, teknik); ekranda
/// gösterilmez, yalnızca kopyalanan tanılamaya girer (bkz. `errorDiagnosticsForSupport`).
private func errorDiagnostics(errors: Result<[DiagnosticErrorEntry], any Error>) -> DiagnosticsSection {
    let title: String = String(localized: "Son hatalar")
    switch errors {
    case .failure:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Okunamadı"))])
    case .success(let entries) where entries.isEmpty:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Bu oturumda hata yok"))])
    case .success(let entries):
        return DiagnosticsSection(title: title, items: entries.map { (entry: DiagnosticErrorEntry) -> DiagnosticsItem in
            DiagnosticsItem(label: entry.date.formatted(date: .abbreviated, time: .standard), value: diagnosticErrorArea(code: entry.code))
        })
    }
}

/// Son hatalar bölümü, günlük henüz okunurken: "hata yok" denmez (yanlış tanı olurdu).
private func pendingErrorDiagnostics() -> DiagnosticsSection {
    DiagnosticsSection(title: String(localized: "Son hatalar"), items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Okunuyor…"))])
}

/// Son hatalar bölümü, kopyalanan tanılamada (destek için): zaman, kod ve günlük metni (kişisel bilgiler ayıklanmış).
private func errorDiagnosticsForSupport(errors: Result<[DiagnosticErrorEntry], any Error>) -> DiagnosticsSection {
    let title: String = String(localized: "Son hatalar")
    switch errors {
    case .failure(let error):
        return DiagnosticsSection(title: title, items: [
            DiagnosticsItem(label: String(localized: "Okunamadı"), value: redactedDiagnosticText(text: String(describing: error), userNames: diagnosticsUserNames())),
        ])
    case .success(let entries) where entries.isEmpty:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Bu oturumda hata yok"))])
    case .success(let entries):
        return DiagnosticsSection(title: title, items: entries.map { (entry: DiagnosticErrorEntry) -> DiagnosticsItem in
            DiagnosticsItem(label: "\(entry.date.formatted(.iso8601)) \(entry.code)", value: entry.message)
        })
    }
}

/// Hatanın günlük kategorisinden (`kategori.düzey`) kullanıcının anlayacağı alan adı. Saf fonksiyondur.
private func diagnosticErrorArea(code: String) -> String {
    let category: String = String(code.split(separator: ".").first ?? "")
    switch category {
    case "Update":
        return String(localized: "Güncelleme")
    case "Hosted", "HostedAccount", "HostedSeams", "HostedGate", "HostedAttest", "HostedAccountData", "AccountData":
        return String(localized: "Hesap")
    case "Deepgram", "CloudLiveSession", "HybridLiveSession", "LiveSession", "WhisperKitEngine", "AppleSpeech":
        return String(localized: "Canlı metin")
    case "SystemAudioCapture", "MicrophoneCapture", "AudioPlayer":
        return String(localized: "Ses")
    case "ProcessMeeting", "ChunkedNote", "LLM", "OnDeviceLLM", "ElevenLabs", "HostedFinal", "LocalFinalPass":
        return String(localized: "Not hazırlama")
    case "Meetings", "CloudStorage":
        return String(localized: "Toplantılar")
    case "Webhook", "Destinations", "MCPRemote", "MCPIntegrations", "LoopbackRedirect", "Channel", "MCP":
        return String(localized: "Bağlantılar")
    default:
        return String(localized: "Uygulama")
    }
}

/// Bu uygulama oturumunun son hataları (log deposundan, ana iş parçacığı dışında).
private func loadAppErrors() async -> Result<[DiagnosticErrorEntry], any Error> {
    let userNames: [String] = diagnosticsUserNames()
    return await Task.detached(priority: .utility) { () -> Result<[DiagnosticErrorEntry], any Error> in
        Result { try loadRecentAppErrors(subsystem: appLogSubsystem, capacity: diagnosticErrorCapacity, userNames: userNames) }
    }.value
}

/// Sunucuya erişimi denetler; adres yoksa nil (bölüm adres hatasını gösterir).
private func probeAPI(base: Result<URL, any Error>) async -> APIHealth? {
    guard case .success(let url) = base else {
        return nil
    }
    do {
        return try await checkAPIHealth(baseURL: url, timeoutSec: healthTimeoutSec)
    } catch {
        diagnosticsLogger.error("Sunucu denetlenemedi, hata: \(String(describing: error), privacy: .private)")
        return .unreachable(reason: String(describing: type(of: error)))
    }
}

/// Tüm bölümler (sunucu denetimi ve son hatalar dahil); arayüz ve kopyalanan metin bunlardan üretilir.
@MainActor
func collectDiagnostics(model: AppModel, updater: AppUpdater, health: APIHealth?, errors: DiagnosticsSection) -> [DiagnosticsSection] {
    let base: Result<URL, any Error> = Result { try diagnosticsAPIBase() }
    var sections: [DiagnosticsSection] = [appDiagnostics(bundle: .main)]
    #if HOSTED_EDITION
    sections.append(hostedAccountDiagnostics(account: .shared))
    #endif
    sections += [
        serverDiagnostics(base: base, health: health),
        permissionDiagnostics(model: model),
        transcriptionDiagnostics(model: model),
        updateDiagnostics(updater: updater),
        errors,
    ]
    return sections
}

/// Sunucuyu denetleyip son hataları okuyarak tanılamanın düz metnini üretir (panoya ve geri bildirime).
@MainActor
func diagnosticsReportText(model: AppModel, updater: AppUpdater) async -> String {
    let health: APIHealth? = await probeAPI(base: Result { try diagnosticsAPIBase() })
    let errors: Result<[DiagnosticErrorEntry], any Error> = await loadAppErrors()
    return diagnosticsText(sections: collectDiagnostics(model: model, updater: updater, health: health, errors: errorDiagnosticsForSupport(errors: errors)), generatedAt: Date())
}

/// Metni panoya koyar.
@MainActor
private func copyToPasteboard(text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Bölümün maddeleri iki sütunlu tabloda: solda soluk etiket, sağda değer (seçilebilir). Etiket sütunu her bölümde
/// aynı genişlikte (değerler bölümler boyunca alt alta hizalı); uzun etiket ve değerler kendi sütununda alta kayar.
private struct DiagnosticsGrid: View {
    let items: [DiagnosticsItem]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { (item: (offset: Int, element: DiagnosticsItem)) in
                GridRow {
                    Text(verbatim: item.element.label)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 190, alignment: .leading)
                        .gridColumnAlignment(.leading)
                    Text(verbatim: item.element.value)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Ayarlar › Tanılama: sürüm, sistem, hesap, sunucuya erişim, izinler, canlı metin modeli, güncelleme ve son hatalar.
/// Ses, metin, not, anahtar, jeton ve e-posta gösterilmez; hepsi yalnızca bu Mac'te, kullanıcı kopyalamadıkça hiçbir
/// yere gitmez.
struct DiagnosticsSettings: View {
    let model: AppModel
    let updater: AppUpdater
    @State private var health: APIHealth?
    /// Son hatalar; okunurken nil.
    @State private var errors: Result<[DiagnosticErrorEntry], any Error>?
    @State private var isRefreshing: Bool = false
    @State private var copied: Bool = false

    var body: some View {
        let errorSection: DiagnosticsSection = errors.map { (loaded: Result<[DiagnosticErrorEntry], any Error>) -> DiagnosticsSection in
            errorDiagnostics(errors: loaded)
        } ?? pendingErrorDiagnostics()
        let sections: [DiagnosticsSection] = collectDiagnostics(model: model, updater: updater, health: health, errors: errorSection)
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: Text("Tanılama")) {
                Text("Sorun bildirirken işe yarar: sürüm, sistem, hesap durumu, sunucuya erişim, izinler, model, güncelleme ve son hatalar. Ses, metin, not, anahtar ve jeton yok; kopyalamadıkça hiçbir yere gitmez.")
            } control: {
                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Yenile") { Task { await refresh() } }
                        .disabled(isRefreshing)
                    // Yenilenirken kopyalanmaz: sunucu denetimi ve son hatalar henüz okunmadı.
                    Button(copied ? "Kopyalandı" : "Tanılama bilgisini kopyala") {
                        guard let errors else {
                            return
                        }
                        let support: [DiagnosticsSection] = collectDiagnostics(
                            model: model, updater: updater, health: health, errors: errorDiagnosticsForSupport(errors: errors)
                        )
                        copyToPasteboard(text: diagnosticsText(sections: support, generatedAt: Date()))
                        copied = true
                    }
                    .buttonStyle(.pillPrimary)
                    .disabled(isRefreshing || errors == nil)
                }
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { (entry: (offset: Int, element: DiagnosticsSection)) in
                SettingsRow(title: Text(verbatim: entry.element.title)) {
                    DiagnosticsGrid(items: entry.element.items)
                        .padding(.top, 4)
                } control: {
                    EmptyView()
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        copied = false
        defer { isRefreshing = false }
        health = nil
        errors = nil
        // Sunucu denetimi (en çok `healthTimeoutSec`) ve günlük okuması birbirini beklemez.
        async let probed: APIHealth? = probeAPI(base: Result { try diagnosticsAPIBase() })
        async let loaded: Result<[DiagnosticErrorEntry], any Error> = loadAppErrors()
        errors = await loaded
        health = await probed
    }
}

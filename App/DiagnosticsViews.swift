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

/// Ekrandaki tarih: arayüz dilinde gün ve saat. Saf fonksiyondur.
private func diagnosticsScreenDate(date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))
}

/// Kopyalanan tanılamadaki tarih: ISO 8601 (destekte saat dilimi karışmasın). Saf fonksiyondur.
private func diagnosticsCopyDate(date: Date) -> String {
    date.formatted(.iso8601)
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
    let modelLabel: String = String(localized: "Mac modeli")
    let model: DiagnosticsItem
    do {
        model = DiagnosticsItem(label: modelLabel, value: try macModelIdentifier(), status: .plain)
    } catch {
        diagnosticsLogger.error("Mac modeli okunamadı, hata: \(String(describing: error), privacy: .private)")
        model = DiagnosticsItem(label: modelLabel, value: String(localized: "okunamadı"), status: .error)
    }
    return DiagnosticsSection(title: String(localized: "Uygulama"), items: [
        DiagnosticsItem(label: String(localized: "Ad"), value: appName, status: .plain),
        DiagnosticsItem(label: String(localized: "Sürüm"), value: appVersionText(version: version, build: build), status: .plain),
        DiagnosticsItem(label: String(localized: "Tür"), value: edition, status: .plain),
        DiagnosticsItem(label: String(localized: "Sistem"), value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", status: .plain),
        model,
    ])
}

#if !HOSTED_EDITION
/// Sunucu bölümü (geliştirici sürümü): rapor sunucusunun adresi ve erişim denetiminin sonucu (HTTP durumu, gecikme).
/// Abonelik sürümünde yerine yalnızca bağlantı durumu gösterilir (bkz. `hostedConnectionDiagnostics`).
private func serverDiagnostics(base: Result<URL, any Error>, health: APIHealth?) -> DiagnosticsSection {
    let title: String = String(localized: "Sunucu")
    let url: URL
    switch base {
    case .success(let value):
        url = value
    case .failure(let error):
        return DiagnosticsSection(title: title, items: [
            DiagnosticsItem(label: String(localized: "Adres"), value: redactedDiagnosticText(text: userFacingMessage(error: error), userNames: diagnosticsUserNames()), status: .error),
        ])
    }
    let accessLabel: String = String(localized: "Erişim")
    let access: DiagnosticsItem
    switch health {
    case .none:
        access = DiagnosticsItem(label: accessLabel, value: String(localized: "Denetleniyor…"), status: .plain)
    case .reachable(let latencyMs):
        access = DiagnosticsItem(label: accessLabel, value: String(localized: "Erişilebilir, \(latencyMs) ms"), status: .plain)
    case .unhealthy(let status, let latencyMs):
        access = DiagnosticsItem(label: accessLabel, value: String(localized: "Yanıt verdi ama sağlıklı değil (HTTP \(status)), \(latencyMs) ms"), status: .attention)
    case .unreachable(let reason):
        access = DiagnosticsItem(label: accessLabel, value: String(localized: "Ulaşılamadı (\(reason))"), status: .error)
    }
    return DiagnosticsSection(title: title, items: [
        DiagnosticsItem(label: String(localized: "Adres"), value: url.host() ?? url.absoluteString, status: .plain),
        access,
    ])
}
#endif

/// Mikrofon izninin satırı; reddedildiyse hata (kayıt yapılamaz).
private func microphoneDiagnostics(permission: AVAudioApplication.recordPermission) -> DiagnosticsItem {
    let label: String = String(localized: "Mikrofon")
    switch permission {
    case .granted: return DiagnosticsItem(label: label, value: String(localized: "İzin verildi"), status: .plain)
    case .denied: return DiagnosticsItem(label: label, value: String(localized: "Reddedildi"), status: .error)
    case .undetermined: return DiagnosticsItem(label: label, value: String(localized: "Henüz sorulmadı"), status: .plain)
    @unknown default: return DiagnosticsItem(label: label, value: String(localized: "Bilinmiyor"), status: .plain)
    }
}

/// Takvim ya da anımsatıcı izninin satırı; reddedildiyse ya da kısıtlıysa dikkat.
private func eventKitDiagnostics(label: String, status: EKAuthorizationStatus) -> DiagnosticsItem {
    switch status {
    case .fullAccess: DiagnosticsItem(label: label, value: String(localized: "Tam erişim"), status: .plain)
    case .writeOnly: DiagnosticsItem(label: label, value: String(localized: "Yalnızca yazma"), status: .plain)
    case .denied: DiagnosticsItem(label: label, value: String(localized: "Reddedildi"), status: .attention)
    case .restricted: DiagnosticsItem(label: label, value: String(localized: "Kısıtlı"), status: .attention)
    case .notDetermined: DiagnosticsItem(label: label, value: String(localized: "Henüz sorulmadı"), status: .plain)
    @unknown default: DiagnosticsItem(label: label, value: String(localized: "Bilinmiyor"), status: .plain)
    }
}

/// Apple Notlar'ı denetleme (Apple Events) izninin satırı; sormadan okunur (Notlar kapalıysa macOS durumu söylemez).
/// Reddedildiyse dikkat.
private func appleEventsDiagnostics() -> DiagnosticsItem {
    let label: String = String(localized: "Apple Notlar (Apple Events)")
    let target: NSAppleEventDescriptor = NSAppleEventDescriptor(bundleIdentifier: notesBundleID)
    let status: OSStatus = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    switch status {
    case noErr: return DiagnosticsItem(label: label, value: String(localized: "İzin verildi"), status: .plain)
    case OSStatus(errAEEventNotPermitted): return DiagnosticsItem(label: label, value: String(localized: "Reddedildi"), status: .attention)
    case OSStatus(errAEEventWouldRequireUserConsent): return DiagnosticsItem(label: label, value: String(localized: "Henüz sorulmadı"), status: .plain)
    case OSStatus(procNotFound): return DiagnosticsItem(label: label, value: String(localized: "Notlar açık değil; durum okunamıyor"), status: .plain)
    default: return DiagnosticsItem(label: label, value: String(localized: "Bilinmiyor (\(status))"), status: .plain)
    }
}

/// İzinler bölümü. Sistem sesi kaydı izninin durumunu macOS sorgulatmaz.
@MainActor
private func permissionDiagnostics(model: AppModel) -> DiagnosticsSection {
    DiagnosticsSection(title: String(localized: "İzinler"), items: [
        microphoneDiagnostics(permission: model.microphonePermission),
        DiagnosticsItem(label: String(localized: "Sistem sesi"), value: String(localized: "macOS bu iznin durumunu bildirmiyor; ilk kayıtta sorulur"), status: .plain),
        eventKitDiagnostics(label: String(localized: "Takvim"), status: EKEventStore.authorizationStatus(for: .event)),
        eventKitDiagnostics(label: String(localized: "Anımsatıcılar"), status: EKEventStore.authorizationStatus(for: .reminder)),
        appleEventsDiagnostics(),
    ])
}

/// Canlı metin bölümü. Geliştirici sürümünde motor ve modelin durumu; abonelik sürümünde yalnızca nerede çalıştığı (bkz.
/// `hostedLiveDiagnostics`).
@MainActor
private func transcriptionDiagnostics(model: AppModel) -> DiagnosticsSection {
    #if HOSTED_EDITION
    return hostedLiveDiagnostics(model: model, account: .shared)
    #else
    let modelLabel: String = String(localized: "Model")
    let modelItem: DiagnosticsItem
    switch (model.liveEngine, model.modelStatus) {
    case (.deepgram, _):
        modelItem = DiagnosticsItem(label: modelLabel, value: String(localized: "Bulut; model gerekmez"), status: .plain)
    case (_, .notLoaded):
        modelItem = DiagnosticsItem(label: modelLabel, value: String(localized: "İndirilmedi; Mac'te canlı metin gerekince indirilir"), status: .plain)
    case (_, .loading):
        modelItem = DiagnosticsItem(label: modelLabel, value: String(localized: "İndiriliyor ya da yükleniyor"), status: .plain)
    case (_, .ready):
        modelItem = DiagnosticsItem(label: modelLabel, value: String(localized: "Hazır"), status: .plain)
    case (_, .failed(let message)):
        modelItem = DiagnosticsItem(
            label: modelLabel, value: String(localized: "Başarısız: \(redactedDiagnosticText(text: message, userNames: diagnosticsUserNames()))"), status: .error
        )
    }
    return DiagnosticsSection(title: String(localized: "Canlı metin"), items: [
        DiagnosticsItem(label: String(localized: "Motor"), value: model.liveEngine.rawValue, status: .plain),
        modelItem,
    ])
    #endif
}

/// Güncelleme bölümü: son denetim (`dateText` biçiminde), otomatik indirme ve bekleyen güncelleme.
@MainActor
private func updateDiagnostics(updater: AppUpdater, dateText: (Date) -> String) -> DiagnosticsSection {
    let title: String = String(localized: "Güncelleme")
    guard updater.isEnabled else {
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Durum"), value: String(localized: "Kapalı (imza anahtarı yok)"), status: .plain)])
    }
    let pending: String = updater.availableUpdate.map { updateHeadline(update: $0) } ?? String(localized: "Yok")
    return DiagnosticsSection(title: title, items: [
        DiagnosticsItem(label: String(localized: "Son denetim"), value: updater.lastCheckDate.map(dateText) ?? String(localized: "Henüz denetlenmedi"), status: .plain),
        DiagnosticsItem(label: String(localized: "Otomatik indirme"), value: updater.automaticallyUpdates ? String(localized: "Etkin") : String(localized: "Kapalı"), status: .plain),
        DiagnosticsItem(label: String(localized: "Bekleyen güncelleme"), value: pending, status: .plain),
    ])
}

/// Son hatalar bölümü, ekranda (en çok 50): zaman ve kullanıcının anlayacağı alan. Kod ve günlük metni geliştirici
/// içindir (Türkçe, teknik); ekranda gösterilmez, yalnızca geliştirici sürümünde kopyalanan tanılamaya girer (bkz.
/// `errorDiagnosticsForSupport`).
private func errorDiagnostics(errors: Result<[DiagnosticErrorEntry], any Error>) -> DiagnosticsSection {
    let title: String = String(localized: "Son hatalar")
    switch errors {
    case .failure:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Okunamadı"), status: .error)])
    case .success(let entries) where entries.isEmpty:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Bu oturumda hata yok"), status: .plain)])
    case .success(let entries):
        return DiagnosticsSection(title: title, items: entries.map { (entry: DiagnosticErrorEntry) -> DiagnosticsItem in
            DiagnosticsItem(label: entry.date.formatted(date: .abbreviated, time: .standard), value: diagnosticErrorArea(code: entry.code), status: .plain)
        })
    }
}

/// Son hatalar bölümü, günlük henüz okunurken: "hata yok" denmez (yanlış tanı olurdu).
private func pendingErrorDiagnostics() -> DiagnosticsSection {
    DiagnosticsSection(title: String(localized: "Son hatalar"), items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Okunuyor…"), status: .plain)])
}

/// Son hatalar bölümü, kopyalanan tanılamada (destek için). Abonelik sürümünde ekrandakiyle aynı (zaman ve alan): kod,
/// günlük metni, istek kimliği, adres ve yanıt gövdesi altyapı ayrıntısıdır, dışarı çıkmaz. Geliştirici sürümünde
/// (yalnızca sahibi) zaman, kod ve günlük metni (kişisel bilgiler ve jetonlar ayıklanmış).
private func errorDiagnosticsForSupport(errors: Result<[DiagnosticErrorEntry], any Error>) -> DiagnosticsSection {
    #if HOSTED_EDITION
    return errorDiagnostics(errors: errors)
    #else
    let title: String = String(localized: "Son hatalar")
    switch errors {
    case .failure(let error):
        return DiagnosticsSection(title: title, items: [
            DiagnosticsItem(label: String(localized: "Okunamadı"), value: redactedDiagnosticText(text: String(describing: error), userNames: diagnosticsUserNames()), status: .error),
        ])
    case .success(let entries) where entries.isEmpty:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Bu oturumda hata yok"), status: .plain)])
    case .success(let entries):
        return DiagnosticsSection(title: title, items: entries.map { (entry: DiagnosticErrorEntry) -> DiagnosticsItem in
            DiagnosticsItem(label: "\(entry.date.formatted(.iso8601)) \(entry.code)", value: entry.message, status: .plain)
        })
    }
    #endif
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

/// Tüm bölümler (sunucu denetimi ve son hatalar dahil); arayüz ve kopyalanan metin bunlardan üretilir, tarihler
/// `dateText` biçiminde (ekranda yerel, kopyalanan metinde ISO 8601). Abonelik sürümünde sunucu yerine yalnızca
/// bağlantı durumu yer alır.
@MainActor
func collectDiagnostics(model: AppModel, updater: AppUpdater, health: APIHealth?, errors: DiagnosticsSection, dateText: (Date) -> String) -> [DiagnosticsSection] {
    let base: Result<URL, any Error> = Result { try diagnosticsAPIBase() }
    var sections: [DiagnosticsSection] = [appDiagnostics(bundle: .main)]
    #if HOSTED_EDITION
    sections += [hostedAccountDiagnostics(account: .shared, dateText: dateText), hostedConnectionDiagnostics(base: base, health: health)]
    #else
    sections.append(serverDiagnostics(base: base, health: health))
    #endif
    sections += [
        permissionDiagnostics(model: model),
        transcriptionDiagnostics(model: model),
        updateDiagnostics(updater: updater, dateText: dateText),
        errors,
    ]
    return sections
}

/// Sunucuyu denetleyip son hataları okuyarak tanılamanın düz metnini üretir (panoya ve geri bildirime).
@MainActor
func diagnosticsReportText(model: AppModel, updater: AppUpdater) async -> String {
    let health: APIHealth? = await probeAPI(base: Result { try diagnosticsAPIBase() })
    let errors: Result<[DiagnosticErrorEntry], any Error> = await loadAppErrors()
    let sections: [DiagnosticsSection] = collectDiagnostics(
        model: model, updater: updater, health: health, errors: errorDiagnosticsForSupport(errors: errors), dateText: diagnosticsCopyDate
    )
    return diagnosticsText(sections: sections, generatedAt: Date())
}

/// Metni panoya koyar.
@MainActor
private func copyToPasteboard(text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Değerin durumuna karşılık gelen uyarı önemi; olağan değerde nil (simge yok). Saf fonksiyondur.
private func noticeSeverity(status: DiagnosticsStatus) -> NoticeSeverity? {
    switch status {
    case .plain: nil
    case .attention: .attention
    case .error: .error
    }
}

/// Bölümün maddeleri iki sütunlu tabloda: solda soluk etiket, sağda değer (seçilebilir). Etiket sütunu her bölümde
/// aynı genişlikte (değerler bölümler boyunca alt alta hizalı); uzun etiket ve değerler kendi sütununda alta kayar.
/// Kötü değer (reddedilen izin, ulaşılamayan sunucu, başarısız işlem) uyarılarla aynı renkte simgeyle gösterilir; iyi
/// değer sade kalır.
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
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let severity = noticeSeverity(status: item.element.status) {
                            Image(systemName: severity.symbol)
                                .imageScale(.small)
                                .foregroundStyle(severity.tint)
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: item.element.value)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Ayarlar › Tanılama: sürüm, sistem, hesap, bağlantı, izinler, canlı metin, güncelleme ve son hatalar. Ses, metin, not,
/// anahtar, jeton ve e-posta gösterilmez; abonelik sürümünde altyapı ve kötüye kullanım önlemlerinin ayrıntısı da
/// gösterilmez (bkz. HostedDiagnostics.swift). Kopyalanan metin ekrandakiyle aynı kurallara uyar; hepsi yalnızca bu
/// Mac'te, kullanıcı kopyalamadıkça hiçbir yere gitmez.
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
        let sections: [DiagnosticsSection] = collectDiagnostics(model: model, updater: updater, health: health, errors: errorSection, dateText: diagnosticsScreenDate)
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: Text("Tanılama")) {
                Text("Sorun bildirirken işe yarar: sürüm, sistem, hesap durumu, bağlantı, izinler, canlı metin, güncelleme ve son hatalar. Ses, metin, not, anahtar ve jeton yok; kopyalamadıkça hiçbir yere gitmez.")
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
                            model: model, updater: updater, health: health, errors: errorDiagnosticsForSupport(errors: errors), dateText: diagnosticsCopyDate
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

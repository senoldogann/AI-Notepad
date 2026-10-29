import AINotepadCore
import AINotepadUI
import os
import SwiftUI

private let maintenanceLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Maintenance")

/// Ayarlar › Genel: otomatik güncelleme (Sparkle) ve elle denetim. Güncelleme kapalıysa (imza anahtarı yok) görünmez.
struct UpdateSettingsRow: View {
    let updater: AppUpdater

    var body: some View {
        if updater.isEnabled {
            SettingsRow(title: Text("Otomatik olarak güncelle")) {
                Text("Yeni sürüm açılışta ve 6 saatte bir denetlenir. Açıkken arka planda indirilir ve uygulamadan çıkınca kurulur; kapalıyken yalnızca haber verilir.")
            } control: {
                HStack(spacing: 8) {
                    Button("Güncellemeleri denetle…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Toggle("Otomatik olarak güncelle", isOn: Binding<Bool>(
                        get: { updater.automaticallyUpdates },
                        set: { (enabled: Bool) -> Void in updater.setAutomaticallyUpdates(enabled: enabled) }
                    ))
                    .settingsToggle()
                }
            }
        }
    }
}

/// Güncelleme şeridinin ve menü satırının başlığı: indirilmişse "hazır", değilse "çıktı". Saf fonksiyondur.
func updateHeadline(update: AvailableAppUpdate) -> String {
    update.isReadyToInstall
        ? String(localized: "\(appName) \(update.version) hazır")
        : String(localized: "\(appName) \(update.version) çıktı")
}

/// Menü çubuğu menüsündeki güncelleme satırı: başlık ve yapılacak iş; kayıt ya da işleme sürerken neden beklendiği.
/// Saf fonksiyondur.
func updateMenuTitle(update: AvailableAppUpdate, isBusy: Bool) -> String {
    let headline: String = updateHeadline(update: update)
    if isBusy {
        return String(localized: "\(headline) — kayıt bitince güncellenebilir")
    }
    return update.isReadyToInstall
        ? String(localized: "\(headline) — Yeniden başlat ve güncelle")
        : String(localized: "\(headline) — Güncelle…")
}

/// Ana penceredeki güncelleme şeridi (çökme şeridiyle aynı sakin görünüm; açılır pencere yok): sürüm, "Neler yeni?"
/// (sürüm notları şeridin içinde açılır) ve "Yeniden başlat ve güncelle". Kayıt ya da işleme sürerken düğme kapalıdır
/// ve nedeni yazar; uygulama yalnızca kullanıcı isteyince ya da çıkışta güncellenir.
struct UpdateBanner: View {
    let updater: AppUpdater
    let update: AvailableAppUpdate
    /// Kayıt ya da işleme sürüyor.
    let isBusy: Bool
    @State private var showsNotes: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoticeBar(severity: .info, title: Text(verbatim: updateHeadline(update: update)), detail: Text(subtitle), onDismiss: { updater.dismissBanner() }) {
                HStack(spacing: 8) {
                    notesLink
                    Button(update.isReadyToInstall ? "Yeniden başlat ve güncelle" : "Güncelle…") { updater.installUpdate() }
                        .buttonStyle(.pill)
                        .disabled(isBusy)
                }
            }
            if showsNotes, let notes = update.releaseNotes {
                ReleaseNotesText(markdown: notes)
                    .padding(.horizontal, 14)
                    .padding(.leading, 23)
                    .padding(.vertical, 10)
                    .background(Theme.soft)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Altyazı: kayıt sürerken neden beklendiği, ertelenmiş kurulum ya da ne olacağı.
    private var subtitle: LocalizedStringKey {
        if updater.isRelaunchPostponed {
            "Kayıt ve işleme bitince uygulama yeniden açılıp güncellenecek."
        } else if isBusy {
            "Kayıt ya da işleme sürerken yeniden başlatılmaz; bitince güncelleyebilirsin. Çıkışta da kendiliğinden kurulur."
        } else if update.isReadyToInstall {
            "İndirildi. Şimdi yeniden başlatabilir ya da uygulamadan çıkınca kurulmasını bekleyebilirsin."
        } else {
            "Yeni sürüm çıktı; \"Güncelle…\" indirip kurar."
        }
    }

    /// "Neler yeni?": gömülü notlar şeridin içinde açılır; yoksa notların sayfası tarayıcıda açılır.
    @ViewBuilder
    private var notesLink: some View {
        if update.releaseNotes != nil {
            Button(showsNotes ? "Notları gizle" : "Neler yeni?") { showsNotes.toggle() }
                .buttonStyle(.hoverPlain)
        } else if let url = update.releaseNotesURL {
            Link("Neler yeni?", destination: url)
                .appFont(size: 12, weight: .regular)
        }
    }
}

/// Sürüm notları (Markdown; appcast'e gömülü). Markdown çözülemezse metin olduğu gibi gösterilir ve uyarı loglanır.
private struct ReleaseNotesText: View {
    let markdown: String

    var body: some View {
        ScrollView {
            Text(attributed)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 220)
    }

    private var attributed: AttributedString {
        do {
            return try AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            maintenanceLogger.warning("Sürüm notları Markdown olarak çözülemedi, düz metin gösteriliyor, hata: \(String(describing: error), privacy: .private)")
            return AttributedString(markdown)
        }
    }
}

/// Çökme şeridindeki gizlilik notu: neyin nereye gittiği. Abonelik sürümünde rapor hesaba bağlı gider ve sunucu
/// jetonsuz raporu kabul etmez (giriş gerekir).
private var crashBannerPrivacyNote: LocalizedStringKey {
    #if HOSTED_EDITION
    "Raporda sürüm, sistem ve hatanın yeri var; toplantı içeriği yok. \"Gönder\"e basınca hesabına bağlı olarak geliştiricinin sunucusuna gider; bunun için giriş yapmış olmalısın."
    #else
    "Raporda sürüm, sistem ve hatanın yeri var; toplantı içeriği ve anahtarlar yok. \"Gönder\"e basınca geliştiricinin sunucusuna gider."
    #endif
}

/// Ayarlar'daki çökme raporları satırının gizlilik notu (bkz. `crashBannerPrivacyNote`).
private var crashSettingsPrivacyNote: LocalizedStringKey {
    #if HOSTED_EDITION
    "macOS'un topladığı çökme ve donma raporları yalnızca bu Mac'te saklanır; hiçbiri kendiliğinden gönderilmez. \"Gönder\" raporu (sürüm, sistem ve hatanın yeri; toplantı içeriği yok) hesabına bağlı olarak geliştiricinin sunucusuna yollar; bunun için giriş yapmış olmalısın."
    #else
    "macOS'un topladığı çökme ve donma raporları yalnızca bu Mac'te saklanır; hiçbiri kendiliğinden gönderilmez. \"Gönder\" raporu (sürüm, sistem ve hatanın yeri; toplantı içeriği ve anahtarlar yok) geliştiricinin sunucusuna yollar."
    #endif
}

/// Ana penceredeki çökme şeridi: önceki açılışta uygulama çöktüyse bir kez sorar. "Gönder" (kullanıcının açık onayı)
/// saklanan raporu geliştiricinin sunucusuna yollar; hiçbir şey kendiliğinden gönderilmez.
struct CrashReportBanner: View {
    let center: CrashReportCenter
    let report: CrashReport

    var body: some View {
        let state: CrashReportSendState? = center.sendStates[report.id]
        // Gönderilemediyse neden ikinci satırda (hata); değilse neyin gönderileceği.
        let failure: String? = if case .failed(let message) = state { message } else { nil }
        NoticeBar(
            severity: failure == nil ? .attention : .error,
            title: Text("\(appName) beklenmedik şekilde kapandı — raporu gönder?"),
            detail: failure.map { Text(verbatim: $0) } ?? Text(crashBannerPrivacyNote),
            onDismiss: state == .sending ? nil : { center.markSeen(id: report.id) }
        ) {
            if state == .sending {
                ProgressView().controlSize(.small)
            } else {
                Button("Gönder") {
                    Task { await center.send(report: report, destination: reportDestination) }
                }
                .buttonStyle(.pill)
            }
        }
    }
}

/// Ayarlar › Genel: saklanan çökme ve donma raporları; her biri geliştiricinin sunucusuna gönderilebilir ya da silinebilir.
struct CrashReportsSettings: View {
    let center: CrashReportCenter
    @State private var isExpanded: Bool = false

    var body: some View {
        SettingsRow(title: Text("Çökme raporları")) {
            Text(crashSettingsPrivacyNote)
            if let problem = center.problem {
                NoticeText(problem, severity: .error)
            }
        } control: {
            Button(isExpanded ? "Çökme raporlarını gizle" : "Çökme raporlarını göster") { isExpanded.toggle() }
        }
        if isExpanded {
            if center.reports.isEmpty {
                SettingsRow(title: Text("Kayıtlı çökme raporu yok.")) {
                    EmptyView()
                } control: {
                    EmptyView()
                }
            }
            ForEach(center.reports) { (report: CrashReport) in
                let diagnostic: CrashDiagnostic = report.primaryDiagnostic
                let state: CrashReportSendState? = center.sendStates[report.id]
                SettingsRow(title: Text(crashReportHeadline(diagnostic: diagnostic))) {
                    Text(verbatim: "\(report.receivedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))) · \(diagnostic.appVersion) · \(diagnostic.osVersion)")
                    if case .failed(let message) = state {
                        NoticeText(message as String, severity: .error)
                    }
                } control: {
                    HStack(spacing: 8) {
                        switch state {
                        case .sending:
                            ProgressView().controlSize(.small)
                        case .sent:
                            Label("Gönderildi", systemImage: "checkmark")
                                .foregroundStyle(Theme.muted)
                        case .failed, .none:
                            Button("Gönder") {
                                Task { await center.send(report: report, destination: reportDestination) }
                            }
                        }
                        Button("Sil", role: .destructive) { center.delete(id: report.id) }
                            .disabled(state == .sending)
                    }
                }
            }
        }
    }
}

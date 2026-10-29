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

/// Güncelleme kartında gösterilen en çok yenilik sayısı.
private let updateToastBulletLimit: Int = 4

/// Ana pencerenin sağ alt köşesindeki güncelleme kartı (açılır pencere değil, içeriğin üstünde küçük kart): uygulama
/// simgesi, "Yeni sürüm hazır" ve sürüm, sürüm notlarından madde madde en çok dört yenilik, "Şimdi güncelle" ve
/// "Sonra". Kayıt ya da işleme sürerken düğme kapalıdır ve nedeni yazar; uygulama yalnızca kullanıcı isteyince ya da
/// çıkışta güncellenir. "Sonra" kartı bu sürüm için kapatır (menüde görünmeye devam eder).
struct UpdateToast: View {
    let updater: AppUpdater
    let update: AvailableAppUpdate
    /// Kayıt ya da işleme sürüyor.
    let isBusy: Bool

    var body: some View {
        let bullets: [String] = update.releaseNotes.map { releaseNoteBullets(markdown: $0, limit: updateToastBulletLimit) } ?? []
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yeni sürüm hazır")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    Text("Sürüm \(update.version)")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button {
                    updater.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 10, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(Text("Kapat"))
            }
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle()
                                .fill(Theme.ink.opacity(0.35))
                                .frame(width: 4.5, height: 4.5)
                                .alignmentGuide(.firstTextBaseline) { (dimensions: ViewDimensions) -> CGFloat in dimensions[.bottom] + 3 }
                            Text(releaseNoteLine(markdown: item.element))
                                .appFont(size: 12.5, weight: .regular)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let note = busyNote {
                Text(note)
                    .appFont(size: 11.5, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let url = update.releaseNotesURL {
                    Link("Tüm notlar", destination: url)
                        .appFont(size: 12, weight: .regular)
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Button("Sonra") { updater.dismissBanner() }
                    .buttonStyle(.pill)
                Button("Şimdi güncelle") { updater.installUpdate() }
                    .buttonStyle(.pillPrimary)
                    .disabled(isBusy)
            }
            .controlSize(.regular)
        }
        .padding(18)
        .frame(width: 344)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: Color.black.opacity(0.14), radius: 22, y: 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Kayıt sürerken ya da kurulum ertelenmişken neden beklendiği; başka durumda nil.
    private var busyNote: LocalizedStringKey? {
        if updater.isRelaunchPostponed {
            return "Kayıt ve işleme bitince uygulama yeniden açılıp güncellenecek."
        }
        if isBusy {
            return "Kayıt ya da işleme sürerken yeniden başlatılmaz; bitince güncelleyebilirsin. Çıkışta da kendiliğinden kurulur."
        }
        return nil
    }
}

/// Sürüm notu maddesi: satır içi Markdown (kalın başlık) çözülür; çözülemezse metin olduğu gibi gösterilir ve uyarı
/// loglanır.
private func releaseNoteLine(markdown: String) -> AttributedString {
    do {
        return try AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    } catch {
        maintenanceLogger.warning("Sürüm notu maddesi Markdown olarak çözülemedi, düz metin gösteriliyor, hata: \(String(describing: error), privacy: .private)")
        return AttributedString(markdown)
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

import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar › Genel: otomatik güncelleme (Sparkle) ve elle denetim. Güncelleme kapalıysa (imza anahtarı yok) görünmez.
struct UpdateSettingsRow: View {
    let updater: AppUpdater

    var body: some View {
        if updater.isEnabled {
            SettingsRow(title: Text("Otomatik olarak güncelle")) {
                Text("Yeni sürüm günde bir denetlenir. Açıkken arka planda indirilir ve uygulamadan çıkınca kurulur; kapalıyken yalnızca haber verilir.")
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appName) beklenmedik şekilde kapandı — raporu gönder?")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text(crashBannerPrivacyNote)
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = state {
                    Text(verbatim: message)
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if state == .sending {
                ProgressView().controlSize(.small)
            } else {
                Button("Gönder") {
                    Task { await center.send(report: report, destination: reportDestination) }
                }
                .buttonStyle(.pill)
            }
            Button("Kapat") { center.markSeen(id: report.id) }
                .buttonStyle(.hoverPlain)
                .disabled(state == .sending)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.soft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
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
                Text(problem).foregroundStyle(.red)
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
                        Text(verbatim: message).foregroundStyle(.red)
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

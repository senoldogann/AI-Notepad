import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar › Genel: otomatik güncelleme (Sparkle) ve elle denetim. Güncelleme kapalıysa (imza anahtarı yok) görünmez.
struct UpdateSettingsRow: View {
    let updater: AppUpdater

    var body: some View {
        if updater.isEnabled {
            SettingsRow(title: Text("Otomatik olarak güncelle")) {
                Text("Yeni sürüm GitHub'dan günde bir denetlenir. Açıkken arka planda indirilir ve uygulamadan çıkınca kurulur; kapalıyken yalnızca haber verilir.")
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

/// Ana penceredeki çökme şeridi: önceki açılışta uygulama çöktüyse bir kez sorar. "GitHub'da bildir" önceden
/// doldurulmuş konuyu tarayıcıda açar (kullanıcı göndermeden önce görür); hiçbir şey kendiliğinden gönderilmez.
struct CrashReportBanner: View {
    let center: CrashReportCenter
    let report: CrashReport
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI-Notepad beklenmedik şekilde kapandı — raporu gönder?")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text("Raporda sürüm, sistem ve hatanın yeri var; toplantı içeriği ve anahtarlar yok. Göndermeden önce GitHub'da görürsün.")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("GitHub'da bildir") {
                if let url = center.issueURL(report: report) {
                    openURL(url)
                    center.markSeen(id: report.id)
                }
            }
            .buttonStyle(.pill)
            Button("Kapat") { center.markSeen(id: report.id) }
                .buttonStyle(.hoverPlain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.soft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Ayarlar › Genel: saklanan çökme ve donma raporları; her biri GitHub'da bildirilebilir ya da silinebilir.
struct CrashReportsSettings: View {
    let center: CrashReportCenter
    @State private var isExpanded: Bool = false
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        SettingsRow(title: Text("Çökme raporları")) {
            Text("macOS'un topladığı çökme ve donma raporları yalnızca bu Mac'te saklanır; hiçbiri kendiliğinden gönderilmez.")
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
                SettingsRow(title: Text(crashReportHeadline(diagnostic: diagnostic))) {
                    Text(verbatim: "\(report.receivedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))) · \(diagnostic.appVersion) · \(diagnostic.osVersion)")
                } control: {
                    HStack(spacing: 8) {
                        Button("GitHub'da bildir") {
                            if let url = center.issueURL(report: report) {
                                openURL(url)
                                center.markSeen(id: report.id)
                            }
                        }
                        Button("Sil", role: .destructive) { center.delete(id: report.id) }
                    }
                }
            }
        }
    }
}

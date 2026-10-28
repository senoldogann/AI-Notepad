import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar'ın en üstünde: önceki açılışta uygulama çöktüyse bir kez sorar. "GitHub'da bildir" önceden doldurulmuş
/// konuyu Safari'de açar (kullanıcı göndermeden önce görür); hiçbir şey kendiliğinden gönderilmez.
struct CrashReportNotice: View {
    let center: CrashReportCenter
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        if let report = center.reportToAnnounce {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("AI-Notepad beklenmedik şekilde kapandı — raporu gönder?", systemImage: "exclamationmark.bubble")
                        .appFont(size: 15, weight: .medium)
                    Text("Raporda sürüm, sistem ve hatanın yeri var; toplantı içeriği ve anahtarlar yok. Göndermeden önce GitHub'da görürsün.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 4)
                Button("GitHub'da bildir") {
                    if let url = center.issueURL(report: report) {
                        openURL(url)
                        center.markSeen(id: report.id)
                    }
                }
                Button("Kapat") { center.markSeen(id: report.id) }
            }
        }
    }
}

/// "Uygulama" bölümündeki satır: saklanan çökme ve donma raporlarının listesi.
struct CrashReportsLink: View {
    let center: CrashReportCenter

    var body: some View {
        NavigationLink {
            CrashReportsList(center: center)
        } label: {
            LabeledContent("Çökme raporlarını göster", value: "\(center.reports.count)")
        }
    }
}

/// Saklanan raporlar: her biri GitHub'da bildirilebilir, kaydırarak silinir.
private struct CrashReportsList: View {
    let center: CrashReportCenter
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        List {
            Section {
                if center.reports.isEmpty {
                    Text("Kayıtlı çökme raporu yok.")
                        .foregroundStyle(Theme.muted)
                }
                ForEach(center.reports) { (report: CrashReport) in
                    let diagnostic: CrashDiagnostic = report.primaryDiagnostic
                    VStack(alignment: .leading, spacing: 4) {
                        Text(crashReportHeadline(diagnostic: diagnostic))
                            .appFont(size: 15, weight: .medium)
                        Text(verbatim: "\(report.receivedAt.formatted(date: .abbreviated, time: .shortened)) · \(diagnostic.appVersion) · \(diagnostic.osVersion)")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                        Button("GitHub'da bildir") {
                            if let url = center.issueURL(report: report) {
                                openURL(url)
                                center.markSeen(id: report.id)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                    .swipeActions {
                        Button("Sil", role: .destructive) { center.delete(id: report.id) }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("iOS'un topladığı çökme ve donma raporları yalnızca bu iPhone'da saklanır; hiçbiri kendiliğinden gönderilmez.")
                    if let problem = center.problem {
                        Text(problem).foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Çökme raporları")
    }
}

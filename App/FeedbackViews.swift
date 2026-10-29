import AINotepadCore
import AINotepadUI
import SwiftUI
import os

private let feedbackLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Feedback")

/// Geri bildirim ve çökme raporlarının gideceği sunucu: abonelik sürümünde hesabın sunucusu (jetonla; giriş yoksa
/// `notSignedIn`), geliştirici sürümünde Info.plist'teki `ReportsAPIBase` (jetonsuz).
@MainActor
func reportDestination() async throws -> ReportDestination {
    #if HOSTED_EDITION
    try await hostedReportDestination()
    #else
    try anonymousReportDestination(bundle: .main)
    #endif
}

/// Ayarlar › Genel: geri bildirim satırı; form küçük bir sayfada (sheet) açılır.
struct FeedbackSettingsRow: View {
    /// Ayarlar › Tanılama'daki metin (formda "Tanılama bilgisini ekle" işaretliyse mesaja eklenir).
    let makeDiagnostics: @MainActor () async -> String
    @State private var isOpen: Bool = false

    var body: some View {
        SettingsRow(title: Text("Geri bildirim gönder")) {
            Text("Hata, öneri ya da soru: doğrudan Gistsmith'in geliştiricisine yaz.")
        } control: {
            Button("Yaz…") { isOpen = true }
        }
        .sheet(isPresented: $isOpen) {
            FeedbackSheet(makeDiagnostics: makeDiagnostics) { isOpen = false }
                .frame(width: 520)
        }
    }
}

/// Formun gönderim durumu.
private enum FeedbackSendState: Equatable {
    case editing
    case sending
    case sent
    /// Gönderilemedi; kullanıcıya gösterilen neden (form açık kalır, yeniden denenebilir).
    case failed(message: String)
}

/// Geri bildirim formu: mesaj (zorunlu), yanıt e-postası (isteğe bağlı), gönderilecek haliyle gösterilen sürüm ve
/// sistem bilgisi ve (baştan kapalı) Ayarlar › Tanılama'daki metin; gönderim kullanıcının "Gönder"iyle olur. Tanılama
/// mesajın sonuna eklenir ve sunucunun mesaj sınırına sığdırılır (bkz. `appendingDiagnostics`).
private struct FeedbackSheet: View {
    let makeDiagnostics: @MainActor () async -> String
    let onClose: @MainActor () -> Void
    @State private var message: String = ""
    @State private var email: String = ""
    @State private var includeDiagnostics: Bool = true
    /// Ayarlar › Tanılama'daki metin de eklensin mi (baştan kapalı).
    @State private var includeFullDiagnostics: Bool = false
    @State private var state: FeedbackSendState = .editing
    @FocusState private var messageFocused: Bool
    private let diagnostics: ReportDiagnostics = currentReportDiagnostics(bundle: .main, platformName: "macOS")

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Geri bildirim gönder").appFont(size: 28, weight: .regular).tracking(-0.4)
            if state == .sent {
                sent
            } else {
                form
            }
        }
        .padding(32)
        .frame(maxWidth: 620, alignment: .leading)
        .interactiveDismissDisabled(state == .sending)
        .onAppear { messageFocused = true }
    }

    private var sent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Teşekkürler, geri bildirimin gönderildi.", systemImage: "checkmark.circle.fill")
                .appFont(size: 15, weight: .medium)
                .foregroundStyle(Theme.ink)
            Button("Kapat") { onClose() }
                .buttonStyle(.pillPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var form: some View {
        let length: Int = reportMessageLength(text: message.trimmingCharacters(in: .whitespacesAndNewlines))
        let isSending: Bool = state == .sending
        let canSend: Bool = !isSending && length > 0 && length <= reportMessageLimit
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Mesaj").appFont(size: 12, weight: .medium).foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(length) / \(reportMessageLimit)")
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(length > reportMessageLimit ? NoticeSeverity.error.tint : Theme.muted)
                }
                TextEditor(text: $message)
                    .appFont(size: 14, weight: .regular)
                    .scrollContentBackground(.hidden)
                    .focused($messageFocused)
                    .frame(height: 150)
                    .padding(6)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Yanıt için e-posta (isteğe bağlı)").appFont(size: 12, weight: .medium).foregroundStyle(Theme.muted)
                TextField("Yanıt için e-posta (isteğe bağlı)", text: $email, prompt: Text("ad@ornek.com"))
                    .textFieldStyle(.plain)
                    .textContentType(.emailAddress)
                    .appFont(size: 14, weight: .regular)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            Toggle("Sürüm ve sistem bilgisini ekle", isOn: $includeDiagnostics)
                .toggleStyle(.checkbox)
                .appFont(size: 13, weight: .regular)
            if includeDiagnostics {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sürüm: \(diagnostics.appVersion)")
                    Text("Sistem: \(diagnostics.os)")
                }
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Tanılama bilgisini ekle", isOn: $includeFullDiagnostics)
                .toggleStyle(.checkbox)
                .appFont(size: 13, weight: .regular)
            if includeFullDiagnostics {
                Text("Ayarlar › Tanılama'daki bilgi (hesap durumu, izinler, sunucuya erişim, son hatalar) mesajın sonuna eklenir; ses, metin, not, anahtar ve jeton eklenmez.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isSending)
        .padding(18)
        .cardSurface(cornerRadius: 16)
        Text(privacyNote)
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        if case .failed(let reason) = state {
            NoticeText(reason as String, severity: .error)
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            Button("Gönder") { send() }
                .buttonStyle(.pillPrimary)
                .disabled(!canSend)
                .keyboardShortcut(.defaultAction)
            Button("Vazgeç") { onClose() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSending)
            if isSending {
                ProgressView().controlSize(.small)
                Text("Gönderiliyor…").appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted)
            }
        }
    }

    /// Neyin nereye gittiği.
    private var privacyNote: LocalizedStringKey {
        #if HOSTED_EDITION
        "Mesajın, yazdıysan e-postan ve işaretliyse tanılama bilgisi Gistsmith'in geliştiricisinin sunucusuna gider ve hesabınla ilişkilendirilir; göndermek için giriş yapmış olmalısın. Toplantı içeriği gönderilmez."
        #else
        "Mesajın, yazdıysan e-postan ve işaretliyse tanılama bilgisi Gistsmith'in geliştiricisinin sunucusuna gider. Toplantı içeriği ve anahtarlar gönderilmez."
        #endif
    }

    private func send() {
        let report: ReportRequest
        do {
            report = try feedbackReport(message: message, email: email, diagnostics: includeDiagnostics ? diagnostics : nil)
        } catch {
            state = .failed(message: userFacingMessage(error: error))
            return
        }
        state = .sending
        Task {
            do {
                let final: ReportRequest = includeFullDiagnostics
                    ? try appendingDiagnostics(report: report, diagnosticsText: await makeDiagnostics(), limit: reportMessageLimit)
                    : report
                try await submitReport(report: final, destination: try await reportDestination())
                state = .sent
            } catch {
                feedbackLogger.error("Geri bildirim gönderilemedi, hata: \(String(describing: error), privacy: .private)")
                state = .failed(message: userFacingMessage(error: error))
            }
        }
    }
}

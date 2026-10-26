import AINotepadCore
import AINotepadUI
import AppKit
import AVFoundation
import SwiftUI

/// Karşılama adımları.
private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case profile
    case keys
    case ready

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Toplantıları anla, hiçbir şeyi kaçırma"
        case .permissions: "İzinler"
        case .profile: "Sen ve motor"
        case .keys: "Anahtarlar"
        case .ready: "Hazırsın"
        }
    }
}

/// Panelin Kurulum sayfası (ilk açılışta bir kez, sonra menüde "Kurulum…"): izinler, ad, motor, anahtarlar;
/// her adım atlanabilir, ayarlar sonra Ayarlar sayfasından değişir.
struct SetupPage: View {
    let model: AppModel
    let shortcuts: ShortcutController
    let onFinish: @MainActor () -> Void
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { (item: OnboardingStep) in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? DesignTokens.meColor : Color.secondary.opacity(0.25))
                        .frame(width: item == step ? 22 : 8, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Adım \(step.rawValue + 1) / \(OnboardingStep.allCases.count)")
            Text(step.title)
                .font(.system(size: 20, weight: .semibold))
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep(model: model)
                case .profile: ProfileStep(model: model)
                case .keys: KeysStep(model: model)
                case .ready: ReadyStep(shortcuts: shortcuts)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step != .welcome {
                    Button("Geri") { move(by: -1) }
                }
                Spacer()
                if step == .ready {
                    Button("Başla") { onFinish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Atla") { onFinish() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button("İleri") { move(by: 1) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(DesignTokens.Spacing.xl)
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    private func move(by offset: Int) {
        step = OnboardingStep(rawValue: step.rawValue + offset) ?? step
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            Text("AI-Notepad, Teams ve Zoom toplantılarını canlı olarak yazıya döker ve Türkçeye çevirir.")
            FeatureRow(symbol: "captions.bubble", text: "Fince ve İngilizce konuşmalar canlı metin ve Türkçe çeviri olarak panelde.")
            FeatureRow(symbol: "sparkles", text: "\"Ne kaçırdım?\" ile son dakikaların Türkçe özeti; toplantı hakkında Türkçe soru.")
            FeatureRow(symbol: "doc.text", text: "Toplantı bitince özet, kararlar, sana düşen görevler ve sözlük.")
            FeatureRow(symbol: "eye.slash", text: "Panel ve ada ekran paylaşımlarında gizlenebilir.")
        }
        .font(.system(size: 14))
    }
}

private struct FeatureRow: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(DesignTokens.meColor)
                .frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Mikrofon ve sistem sesi izinleri.
private struct PermissionsStep: View {
    let model: AppModel
    @State private var microphone: AVAudioApplication.recordPermission = .undetermined
    @State private var systemAudio: ProbeState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            PermissionRow(
                symbol: "mic",
                title: "Mikrofon",
                detail: "Senin konuşmaların (\"Sen\").",
                status: microphoneText,
                isGranted: microphone == .granted
            ) {
                Button("İzin ver") {
                    Task {
                        _ = await model.requestMicrophonePermission()
                        microphone = model.microphonePermission
                    }
                }
                .disabled(microphone != .undetermined)
            }
            PermissionRow(
                symbol: "speaker.wave.2",
                title: "Sistem sesi",
                detail: "Toplantıdaki diğer kişiler (Teams, Zoom). macOS izni ilk denemede sorar.",
                status: systemAudioText,
                isGranted: systemAudio == .started
            ) {
                Button("İzin penceresini aç") {
                    systemAudio = .running
                    Task {
                        do {
                            try await model.probeSystemAudio()
                            systemAudio = .started
                        } catch {
                            systemAudio = .failed(userFacingMessage(error: error))
                        }
                    }
                }
                .disabled(systemAudio == .running)
            }
            HStack {
                Text("İzni reddettiysen:")
                    .foregroundStyle(.secondary)
                Button("Sistem Ayarları › Gizlilik ve Güvenlik") {
                    // Sistem sesi kaydı izni macOS'ta "Ekran ve Sistem Sesi Kaydı" bölümündedir.
                    openPrivacySettings(anchor: microphone == .denied ? "Privacy_Microphone" : "Privacy_ScreenCapture")
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
        .onAppear { microphone = model.microphonePermission }
        // Kullanıcı izni Sistem Ayarları'nda değiştirip geri dönünce durum yenilenir.
        // Panel uygulamayı etkinleştirmediği için panelin yeniden anahtar pencere olması da dinlenir.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { (_: Notification) in
            microphone = model.microphonePermission
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { (_: Notification) in
            microphone = model.microphonePermission
        }
    }

    private var microphoneText: String {
        switch microphone {
        case .granted: String(localized: "İzin verildi")
        case .denied: String(localized: "Reddedildi: Sistem Ayarları'ndan aç")
        case .undetermined: String(localized: "Henüz sorulmadı")
        @unknown default: String(localized: "Bilinmiyor")
        }
    }

    private var systemAudioText: String {
        switch systemAudio {
        case .idle: String(localized: "macOS bu iznin durumunu göstermez; deneyerek açılır")
        case .running: String(localized: "Deneniyor…")
        case .started: String(localized: "Yakalama başladı. İzin penceresi çıktıysa \"İzin Ver\"i seçtiysen hazır.")
        case .failed(let message): message
        }
    }
}

private enum ProbeState: Equatable {
    case idle
    case running
    case started
    case failed(String)
}

private struct PermissionRow<Action: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let status: String
    let isGranted: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.meColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
                Label(status, systemImage: isGranted ? "checkmark.circle.fill" : "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(isGranted ? .green : .secondary)
            }
            Spacer()
            action()
        }
    }
}

/// Gizlilik bölümünü Sistem Ayarları'nda açar.
@MainActor
private func openPrivacySettings(anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
        return
    }
    NSWorkspace.shared.open(url)
}

/// Ad ve canlı metin motoru.
private struct ProfileStep: View {
    let model: AppModel
    @AppStorage(SettingsKey.userName) private var userName: String = ""

    var body: some View {
        Form {
            TextField("Adın", text: $userName, prompt: Text("ör. Doğan"))
            Picker("Canlı metin", selection: Binding<LiveEngine>(
                get: { model.liveEngine },
                set: { (engine: LiveEngine) -> Void in Task { await model.selectEngine(engine: engine) } }
            )) {
                Text("Deepgram (bulut, en hızlı)").tag(LiveEngine.deepgram)
                Text("Mac'te (WhisperKit, internetsiz)").tag(LiveEngine.whisperKit)
            }
            .pickerStyle(.radioGroup)
            Text(model.liveEngine == .deepgram
                ? "Deepgram ve ElevenLabs anahtarı gerekir. Konuşmacılar canlı ayrılır."
                : "İlk açılışta model (~630 MB) indirilir ve hazırlanır; birkaç dakika sürebilir.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
    }
}

/// Seçili motorun ve LLM'in anahtarları.
private struct KeysStep: View {
    let model: AppModel

    var body: some View {
        Form {
            if model.liveEngine == .deepgram {
                SecretField(title: "Deepgram", account: .deepgram, onChange: model.settingsChanged)
                SecretField(title: "ElevenLabs", account: .elevenlabs, onChange: model.settingsChanged)
            }
            SecretField(title: "Anthropic (Claude)", account: .anthropic, onChange: model.settingsChanged)
            Text("Çeviri, özet ve not için Claude kullanılır. OpenAI, Ollama ya da OpenCode Go'yu Ayarlar › LLM'den seçebilirsin.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Kısayollar ve ilk kullanım.
private struct ReadyStep: View {
    let shortcuts: ShortcutController

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            ForEach(ShortcutAction.allCases, id: \.self) { (action: ShortcutAction) in
                HStack {
                    Text(keyBindingDisplay(binding: shortcuts.currentBinding(action: action)))
                        .monospaced()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text(action.title)
                }
            }
            Text("Kaydı paneldeki \"Başlat\" düğmesiyle ya da menüden başlat. Toplantı bitince panel toplantının sayfasını açar: görevlerin en üstte.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14))
    }
}

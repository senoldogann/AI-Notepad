import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar: canlı motor seçimi ve bulut API anahtarları (Keychain).
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Canlı metin") {
                Picker("Motor", selection: Binding<LiveEngine>(
                    get: { model.liveEngine },
                    set: { (engine: LiveEngine) -> Void in
                        Task { await model.selectEngine(engine: engine) }
                    }
                )) {
                    Text("Deepgram (bulut, ~1 sn)").tag(LiveEngine.deepgram)
                    Text("Mac'te (WhisperKit, internetsiz)").tag(LiveEngine.whisperKit)
                }
                Text("Deepgram seçiliyken konuşmacılar ElevenLabs ile dakikada bir ayrılır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Türkçe çeviri") {
                Picker("Görünüm", selection: Binding<DisplayMode>(
                    get: { model.displayMode },
                    set: { (mode: DisplayMode) -> Void in model.selectDisplayMode(mode: mode) }
                )) {
                    Text("İki dil (orijinal + Türkçe)").tag(DisplayMode.bilingual)
                    Text("Sadece Türkçe").tag(DisplayMode.turkishOnly)
                }
            }
            Section("API anahtarları") {
                SecretField(title: "Deepgram", account: .deepgram)
                SecretField(title: "ElevenLabs", account: .elevenlabs)
                SecretField(title: "Anthropic (Claude)", account: .anthropic)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// Tek bir anahtar alanı: gizli giriş, kaydet, kayıt durumu. Kayıtlı değer hiçbir zaman gösterilmez.
private struct SecretField: View {
    let title: String
    let account: SecretAccount

    @State private var input: String = ""
    @State private var status: SecretStatus = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(title, text: $input, prompt: Text("Yeni anahtarı yapıştır"))
                Button("Kaydet") {
                    status = save(account: account, value: input.trimmingCharacters(in: .whitespacesAndNewlines))
                    if status == .saved {
                        input = ""
                    }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            switch status {
            case .unknown:
                EmptyView()
            case .saved:
                Label("Kayıtlı", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            case .missing:
                Label("Kayıtlı değil", systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.caption)
            case .failed(let message):
                Text(message).foregroundStyle(.red).font(.caption)
            }
        }
        .onAppear {
            status = currentStatus(account: account)
        }
    }
}

private enum SecretStatus: Equatable {
    case unknown
    case saved
    case missing
    case failed(String)
}

private func currentStatus(account: SecretAccount) -> SecretStatus {
    do {
        return try secretExists(service: keychainService, account: account) ? .saved : .missing
    } catch {
        return .failed("Keychain okunamadı: \(error)")
    }
}

private func save(account: SecretAccount, value: String) -> SecretStatus {
    do {
        try saveSecret(service: keychainService, account: account, value: value)
        return .saved
    } catch {
        return .failed("Kaydedilemedi: \(error)")
    }
}

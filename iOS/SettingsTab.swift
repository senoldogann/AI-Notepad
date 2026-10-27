import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar: bulut anahtarları, toplantı dili, ad ve sürüm (iCloud eşitleme aşama 4'te).
struct PhoneSettingsTab: View {
    let store: PhoneStore
    @AppStorage(PhoneSettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(PhoneSettingsKey.userName) private var userName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("iCloud ile eşitle", isOn: Binding<Bool>(
                        get: { store.cloud.location == .iCloud },
                        set: { (enabled: Bool) -> Void in
                            Task { await store.cloud.setEnabled(enabled) { store.reload() } }
                        }
                    ))
                    .disabled(store.cloud.state == .working)
                    switch store.cloud.state {
                    case .working:
                        Label("Toplantılar taşınıyor…", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Theme.muted)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    case .idle:
                        if store.downloadingCount > 0 {
                            Label("\(store.downloadingCount) toplantı iCloud'dan iniyor…", systemImage: "icloud.and.arrow.down")
                                .foregroundStyle(Theme.muted)
                        }
                    }
                } header: {
                    Text("Eşitleme")
                } footer: {
                    Text("Biten toplantılar iCloud Drive'a taşınır ve Mac'teki AI-Notepad'de de görünür (Mac'te de açık olmalı). Kayıt ve işleme bu iPhone'da yapılır. Kapatınca iCloud'daki toplantılar bu iPhone'a taşınır.")
                }
                Section {
                    KeyRow(account: .deepgram, title: "Deepgram", purpose: "Canlı metin")
                    KeyRow(account: .elevenlabs, title: "ElevenLabs", purpose: "Konuşmacılar ve son geçiş")
                    KeyRow(account: .anthropic, title: "Anthropic (Claude)", purpose: "Çeviri ve not")
                } header: {
                    Text("Anahtarlar")
                } footer: {
                    Text("Mac'te Ayarlar › Anahtarlar › \"iPhone'a gönder\" dersen anahtarlar iCloud Anahtar Zinciri ile buraya gelir. Burada girdiğin anahtar yalnız bu iPhone'da saklanır ve öncelik onundur.")
                }
                Section("Toplantı") {
                    Picker("Ana toplantı dili", selection: $primaryLanguage) {
                        ForEach(MeetingLanguage.allCases, id: \.rawValue) { (language: MeetingLanguage) in
                            Text(languageName(language: language)).tag(language.rawValue)
                        }
                    }
                    TextField("Adın (notta senin görevlerin için)", text: $userName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                Section("Uygulama") {
                    LabeledContent("Sürüm", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("Toplantılar", value: "\(store.meetings.count)")
                }
            }
            .navigationTitle("Ayarlar")
        }
    }
}

/// Bir bulut anahtarı: kayıtlı mı, yenisini yapıştırma ve silme. Değer hiçbir zaman gösterilmez.
private struct KeyRow: View {
    let account: SecretAccount
    let title: String
    let purpose: LocalizedStringKey
    @State private var value: String = ""
    @State private var isSaved: Bool = false
    /// Mac'ten iCloud Anahtar Zinciri ile gelen kopya var.
    @State private var isFromMac: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appFont(size: 15, weight: .medium)
                    Text(purpose).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                }
                Spacer()
                if isFromMac {
                    Label("Mac'ten", systemImage: "icloud.fill")
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(.green)
                } else if isSaved {
                    Label("Kayıtlı", systemImage: "checkmark.circle.fill")
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(.green)
                }
            }
            HStack {
                SecureField(isSaved ? "Değiştirmek için yenisini yapıştır" : "Anahtarı yapıştır", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Kaydet") { save() }
                    .disabled(trimmedValue.isEmpty)
            }
            if let errorMessage {
                Text(errorMessage).appFont(size: 12, weight: .regular).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            if isSaved {
                Button("Sil", role: .destructive) { delete() }
            }
        }
        .task { refresh() }
    }

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        do {
            try saveSecret(service: keychainService, account: account, value: trimmedValue)
            value = ""
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func delete() {
        do {
            try deleteSecret(service: keychainService, account: account)
            refresh()
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func refresh() {
        do {
            isFromMac = try syncedSecretExists(service: keychainService, account: account)
            isSaved = try secretExists(service: keychainService, account: account)
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

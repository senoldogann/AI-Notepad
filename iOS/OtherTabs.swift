import AINotepadCore
import AINotepadUI
import SwiftUI

/// Henüz dolmamış sekme (aşama 3).
struct ComingSoonTab: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        NavigationStack {
            VStack {
                EmptyStateCard(symbol: symbol, title: title, message: "Bu bölüm bir sonraki sürümde geliyor.")
                    .padding(16)
                Spacer()
            }
            .background(Theme.background)
            .navigationTitle(title)
        }
    }
}

/// Ayarlar: bulut anahtarları, toplantı dili, ad ve sürüm (iCloud eşitleme aşama 4'te).
struct PhoneSettingsTab: View {
    let store: PhoneStore
    @AppStorage(PhoneSettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(PhoneSettingsKey.userName) private var userName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    KeyRow(account: .deepgram, title: "Deepgram", purpose: "Canlı metin")
                    KeyRow(account: .elevenlabs, title: "ElevenLabs", purpose: "Konuşmacılar ve son geçiş")
                    KeyRow(account: .anthropic, title: "Anthropic (Claude)", purpose: "Çeviri ve not")
                } header: {
                    Text("Anahtarlar")
                } footer: {
                    Text("Anahtarlar bu iPhone'un Anahtar Zinciri'nde saklanır, hiçbir yere gönderilmez. Mac'teki anahtarların iCloud ile gelmesi eşitleme sürümünde açılıyor.")
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
                Section("Eşitleme") {
                    Text("Toplantılar şimdilik bu iPhone'da saklanır. iCloud ile Mac'le eşitleme bir sonraki sürümlerde açılıyor.")
                        .foregroundStyle(Theme.muted)
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
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appFont(size: 15, weight: .medium)
                    Text(purpose).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                }
                Spacer()
                if isSaved {
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
            isSaved = try secretExists(service: keychainService, account: account)
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

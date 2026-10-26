import AINotepadCore
import AppKit
import SwiftUI

/// Tek bir anahtar alanı: gizli giriş, kaydet/kaldır, kayıt durumu. Kayıtlı değer hiçbir zaman gösterilmez.
/// Kaydetme ya da kaldırma sonrası `onChange` çağrılır (açık kayıtta çeviri yeni anahtarla sürsün).
struct SecretField: View {
    let title: LocalizedStringKey
    let account: SecretAccount
    let onChange: @MainActor () -> Void

    @State private var input: String = ""
    @State private var status: SecretStatus = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(title, text: $input, prompt: Text(status == .saved ? "Kayıtlı · değiştirmek için yapıştır" : "Anahtarı yapıştır"))
                // Panel uygulamayı öne getirmediği için ⌘V menü kısayolu her zaman ulaşmayabilir: panodan doğrudan al.
                Button("Yapıştır") {
                    input = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                Button("Kaydet") {
                    status = save(account: account, value: input.trimmingCharacters(in: .whitespacesAndNewlines))
                    if status == .saved {
                        input = ""
                        onChange()
                    }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if status == .saved {
                    Button("Kaldır", role: .destructive) {
                        status = remove(account: account)
                        onChange()
                    }
                }
            }
            switch status {
            case .unknown:
                EmptyView()
            case .saved:
                Label("Kayıtlı", systemImage: "checkmark.circle.fill").foregroundStyle(.green).appFont(size: 11, weight: .regular)
            case .missing:
                Label("Kayıtlı değil", systemImage: "exclamationmark.circle").foregroundStyle(.orange).appFont(size: 11, weight: .regular)
            case .failed(let message):
                Text(message).foregroundStyle(.red).appFont(size: 11, weight: .regular)
            }
        }
        .task {
            status = await currentStatus(account: account)
        }
    }
}

private enum SecretStatus: Equatable {
    case unknown
    case saved
    case missing
    case failed(String)
}

/// Kayıt durumu; değer okunmadığı için izin penceresi açılmaz. Arka planda sorulur.
private func currentStatus(account: SecretAccount) async -> SecretStatus {
    do {
        let exists: Bool = try await Task.detached { try secretExists(service: keychainService, account: account) }.value
        return exists ? .saved : .missing
    } catch {
        return .failed(userFacingMessage(error: error))
    }
}

private func save(account: SecretAccount, value: String) -> SecretStatus {
    do {
        try saveSecret(service: keychainService, account: account, value: value)
        return .saved
    } catch {
        return .failed(String(localized: "Kaydedilemedi: \(userFacingMessage(error: error))"))
    }
}

private func remove(account: SecretAccount) -> SecretStatus {
    do {
        try deleteSecret(service: keychainService, account: account)
        return .missing
    } catch {
        return .failed(String(localized: "Kaldırılamadı: \(userFacingMessage(error: error))"))
    }
}

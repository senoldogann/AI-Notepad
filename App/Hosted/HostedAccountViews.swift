import AINotepadCore
import AINotepadUI
import SwiftUI

/// Deneme sayacı: "3 toplantıdan 2 tanesi kaldı" (iyelik eki sayıya göre değiştiği için "tanesi"). Saf fonksiyondur.
func hostedTrialText(left: Int, total: Int) -> String {
    String(localized: "\(total) toplantıdan \(left) tanesi kaldı")
}

/// Aylık kullanım: "Bu ay 2,5 / 10 saat". Saf fonksiyondur.
func hostedMonthlyUsageText(used: Double, cap: Double) -> String {
    let style: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(0...1)).locale(interfaceLocale())
    return String(localized: "Bu ay \(used.formatted(style)) / \(cap.formatted(style)) saat")
}

/// Giriş: uygulama içi giriş penceresinde Apple ya da Google hesabı seçilir, pencere kapanınca giriş tamamlanır
/// (Developer ID ile dağıtılan uygulama Apple ile girişi kendisi yapamaz; giriş sitede). Kurulumda ve Ayarlar › Hesap'ta
/// aynı.
struct HostedSignInPanel: View {
    let account: HostedAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3 toplantı ya da ilk toplantından itibaren 7 gün ücretsiz; anahtar gerekmez. Sonrası aylık abonelikle.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await account.signIn() }
            } label: {
                Text("Giriş yap")
                    .frame(width: 228)
            }
            .buttonStyle(.pill)
            .disabled(account.isWorking || account.pendingBrowserSignIn != nil)
            Text(account.pendingBrowserSignIn == nil
                ? "Açılan giriş penceresinde Apple ya da Google hesabını seçersin; pencere kapanınca giriş tamamlanır."
                : "Giriş penceresinde Apple ya da Google hesabını seç. Vazgeçersen pencereyi kapatman yeter.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HostedAccountError(account: account)
        }
    }
}

/// Son hesap işleminin hatası.
struct HostedAccountError: View {
    let account: HostedAccount

    var body: some View {
        if let message = account.errorMessage {
            Text(verbatim: message)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Ayarlar › Hesap: giriş, deneme sayacı ya da abonelik durumu, aylık kullanım, ödeme, çıkış ve hesap silme.
struct HostedAccountSettings: View {
    let account: HostedAccount
    /// Hesap silme satır içinde onaylanır (açılır pencere yok).
    @State private var confirmingDelete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch account.state {
            case .loading:
                ProgressView().controlSize(.small).padding(.vertical, 16)
            case .unavailable(let message):
                SettingsRow(title: Text("Hesap kullanılamıyor")) {
                    Text(verbatim: message).foregroundStyle(.red)
                } control: {
                    EmptyView()
                }
            case .signedOut:
                HostedSignInPanel(account: account)
                    .padding(.vertical, 16)
            case .signedIn(let entitlements):
                signedIn(entitlements: entitlements)
            case .signedInStatusUnknown(let message):
                SettingsRow(title: Text("Plan")) {
                    Text("Giriş yapıldı; hesap durumu şu an okunamıyor. Bağlantı gelince kendiliğinden yenilenir.")
                    Text(verbatim: message).foregroundStyle(.orange)
                } control: {
                    Button("Yeniden dene") { Task { await account.refresh() } }
                        .disabled(account.isWorking)
                }
                HostedSignOutRow(account: account)
                HostedAccountError(account: account)
                    .padding(.top, 12)
            }
        }
        .task { await account.refresh() }
    }

    @ViewBuilder
    private func signedIn(entitlements: HostedEntitlements) -> some View {
        let status: HostedPlanStatus = hostedPlanStatus(entitlements: entitlements)
        SettingsRow(title: Text("Plan")) {
            switch status {
            case .trial(let left, let total):
                Text(verbatim: hostedTrialText(left: left, total: total))
                if left == 0 {
                    Text("Deneme bitti; yeni toplantı için abone ol.").foregroundStyle(Theme.ink)
                } else if let trialEndsAt = entitlements.trialEndsAt {
                    Text("Deneme \(trialEndsAt.formatted(date: .abbreviated, time: .omitted)) tarihinde biter.")
                }
            case .subscribed(let renewsAt):
                Text("Abonelik etkin; dönem \(renewsAt.formatted(date: .abbreviated, time: .omitted)) tarihinde yenilenir.")
            case .ending(let endsAt):
                Text("Abonelik iptal edildi; \(endsAt.formatted(date: .abbreviated, time: .omitted)) tarihine kadar kullanabilirsin, yenilenmez.")
            case .grace(let endsAt):
                Text("Ödeme alınamadı; erişimin \(endsAt.formatted(date: .abbreviated, time: .omitted)) tarihine kadar sürer. \"Hesabı yönet\"ten kartını güncelle.")
                    .foregroundStyle(.orange)
            }
        } control: {
            HStack(spacing: 8) {
                if entitlements.subscription != nil {
                    Button("Hesabı yönet") { Task { await account.manageSubscription() } }
                        .disabled(account.isWorking)
                }
                if case .trial = status {
                    Button("Abone ol") { Task { await account.subscribe() } }
                        .buttonStyle(.pillPrimary)
                        .disabled(account.isWorking)
                }
            }
        }
        SettingsRow(title: Text("Kullanım")) {
            Text(verbatim: hostedMonthlyUsageText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap))
            Text("Adil kullanım sınırı; ay başında sıfırlanır. Canlı metin bu Mac'te yazılır ve sınırdan düşmez.")
        } control: {
            ProgressView(value: min(entitlements.monthlyHoursUsed, entitlements.monthlyHoursCap), total: max(entitlements.monthlyHoursCap, 0.1))
                .frame(width: 140)
        }
        HostedSignOutRow(account: account)
        SettingsRow(title: Text("Hesabı sil")) {
            Text("Hesabın, aboneliğin (hemen iptal edilir) ve sunucudaki tüm kayıtların silinir. Bu Mac'teki toplantılar ve notlar silinmez.")
            if confirmingDelete {
                Text("Emin misin? Bu işlem geri alınamaz.").foregroundStyle(.red)
            }
        } control: {
            HStack(spacing: 8) {
                if confirmingDelete {
                    Button("Vazgeç") { confirmingDelete = false }
                    Button("Hesabı kalıcı olarak sil", role: .destructive) {
                        confirmingDelete = false
                        Task { await account.deleteAccount() }
                    }
                    .disabled(account.isWorking)
                } else {
                    Button("Hesabı sil…", role: .destructive) { confirmingDelete = true }
                        .disabled(account.isWorking)
                }
            }
        }
        HostedAccountError(account: account)
            .padding(.top, 12)
    }
}

/// Ayarlar › Hesap'taki çıkış satırı (hak durumu okunamasa da çıkış yapılabilir).
private struct HostedSignOutRow: View {
    let account: HostedAccount

    var body: some View {
        SettingsRow(title: Text("Oturum")) {
            Text("Bu Mac'teki oturumu kapatır; toplantıların ve notların bu Mac'te kalır.")
        } control: {
            Button("Çıkış yap") { Task { await account.signOut() } }
                .disabled(account.isWorking)
        }
    }
}

/// Kurulumun hesap adımı (geliştirici sürümündeki anahtar adımının yerine): giriş ve ücretsiz toplantı sayacı.
struct HostedSignInStep: View {
    let account: HostedAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch account.state {
            case .loading:
                ProgressView().controlSize(.small)
            case .unavailable(let message):
                Text(verbatim: message)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(.red)
            case .signedOut:
                HostedSignInPanel(account: account)
            case .signedIn(let entitlements):
                Label("Giriş yapıldı", systemImage: "checkmark.circle.fill")
                    .appFont(size: 15, weight: .medium)
                    .foregroundStyle(Theme.ink)
                switch hostedPlanStatus(entitlements: entitlements) {
                case .trial(let left, let total):
                    Text(verbatim: hostedTrialText(left: left, total: total))
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                case .subscribed, .ending, .grace:
                    Text("Aboneliğin etkin.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                HostedAccountError(account: account)
            case .signedInStatusUnknown:
                Label("Giriş yapıldı", systemImage: "checkmark.circle.fill")
                    .appFont(size: 15, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text("Hesap durumu şu an okunamıyor; bağlantı gelince kendiliğinden yenilenir.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .task { await account.refresh() }
    }
}

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
            NoticeText(message as String, severity: .error)
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Ayarlar › Hesap: giriş, deneme sayacı ya da abonelik durumu, aylık kullanım, ödeme, çıkış ve hesap silme.
struct HostedAccountSettings: View {
    let account: HostedAccount
    /// Kayıt, işleme ya da içe aktarma sürüyor: çıkış ve hesap silme kapalıdır (süren toplantının sunucu oturumu ve
    /// faturası başka hesaba ya da silinmiş hesaba yazılmasın; bitince açılır).
    let isMeetingInFlight: Bool
    /// Hesap silme satır içinde onaylanır (açılır pencere yok).
    @State private var confirmingDelete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch account.state {
            case .loading:
                ProgressView().controlSize(.small).padding(.vertical, 16)
            case .unavailable(let message):
                SettingsRow(title: Text("Hesap kullanılamıyor")) {
                    NoticeText(message as String, severity: .error)
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
                    NoticeText(message as String, severity: .attention)
                } control: {
                    Button("Yeniden dene") { Task { await account.refresh() } }
                        .disabled(account.isWorking)
                }
                HostedSignOutRow(account: account, isMeetingInFlight: isMeetingInFlight)
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
            case .trial:
                // Kalan toplantılar, bitiş ve "Abone ol" aşağıdaki kullanım kartında.
                Text("Ücretsiz deneme")
            case .subscribed(let renewsAt):
                Text("Abonelik etkin; dönem \(hostedDayText(date: renewsAt)) tarihinde yenilenir.")
            case .ending(let endsAt):
                Text("Abonelik iptal edildi; \(hostedDayText(date: endsAt)) tarihine kadar kullanabilirsin, yenilenmez.")
            case .grace(let endsAt):
                NoticeText("Ödeme alınamadı; erişimin \(hostedDayText(date: endsAt)) tarihine kadar sürer. \"Hesabı yönet\"ten kartını güncelle.", severity: .attention)
            case .expired(let endedAt):
                Text("Aboneliğin \(hostedDayText(date: endedAt)) tarihinde sona erdi; toplantıların ve notların bu Mac'te.")
            }
        } control: {
            HStack(spacing: 8) {
                if entitlements.subscription != nil {
                    Button("Hesabı yönet") { Task { await account.manageSubscription() } }
                        .disabled(account.isWorking)
                }
            }
        }
        HostedUsageCard(account: account, entitlements: entitlements)
        HostedSignOutRow(account: account, isMeetingInFlight: isMeetingInFlight)
        SettingsRow(title: Text("Hesabı sil")) {
            Text("Hesabın, aboneliğin (hemen iptal edilir) ve sunucudaki tüm kayıtların silinir. Bu Mac'teki toplantılar ve notlar silinmez.")
            if isMeetingInFlight {
                NoticeText("Kayıt ya da işleme sürüyor; bitince hesabı silebilirsin.", severity: .attention)
            } else if confirmingDelete {
                NoticeText("Emin misin? Bu işlem geri alınamaz.", severity: .error)
            }
        } control: {
            HStack(spacing: 8) {
                if confirmingDelete {
                    Button("Vazgeç") { confirmingDelete = false }
                    Button("Hesabı kalıcı olarak sil", role: .destructive) {
                        confirmingDelete = false
                        Task { await account.deleteAccount() }
                    }
                    .disabled(account.isWorking || isMeetingInFlight)
                } else {
                    Button("Hesabı sil…", role: .destructive) { confirmingDelete = true }
                        .disabled(account.isWorking || isMeetingInFlight)
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
    let isMeetingInFlight: Bool

    var body: some View {
        SettingsRow(title: Text("Oturum")) {
            Text("Bu Mac'teki oturumu kapatır; toplantıların ve notların bu Mac'te kalır.")
            if isMeetingInFlight {
                NoticeText("Kayıt ya da işleme sürüyor; bitince çıkış yapabilirsin.", severity: .attention)
            }
        } control: {
            Button("Çıkış yap") { Task { await account.signOut() } }
                .disabled(account.isWorking || isMeetingInFlight)
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
                NoticeText(message as String, severity: .error)
                    .appFont(size: 13, weight: .regular)
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
                case .expired:
                    Text("Aboneliğin sona erdi; yeni kayıt için yeniden abone ol.")
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

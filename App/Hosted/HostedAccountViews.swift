import AINotepadCore
import AINotepadUI
import AuthenticationServices
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

/// Apple ile ve Google ile giriş; kurulumda ve Ayarlar › Hesap'ta aynı.
struct HostedSignInPanel: View {
    let account: HostedAccount
    /// Apple isteğine verilen nonce'un ham hali (yanıt gelince sunucuya gider).
    @State private var pendingNonce: String?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("İlk 3 toplantı ücretsiz; anahtar gerekmez. Sonrası aylık abonelikle.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            SignInWithAppleButton(.signIn) { (request: ASAuthorizationAppleIDRequest) -> Void in
                request.requestedScopes = [.email]
                do {
                    let nonce: String = try makeHostedNonce()
                    pendingNonce = nonce
                    request.nonce = hostedNonceHash(nonce: nonce)
                } catch {
                    pendingNonce = nil
                    account.errorMessage = userFacingMessage(error: error)
                }
            } onCompletion: { (result: Result<ASAuthorization, any Error>) -> Void in
                guard let nonce = pendingNonce else {
                    account.errorMessage = String(localized: "Apple ile giriş başlatılamadı; yeniden dene.")
                    return
                }
                pendingNonce = nil
                Task { await account.completeAppleSignIn(result: result, nonce: nonce) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(width: 260, height: 36)
            .disabled(account.isWorking)
            Button {
                account.startGoogleSignIn()
            } label: {
                Text("Google ile devam et")
                    .frame(width: 228)
            }
            .buttonStyle(.pill)
            .disabled(account.isWorking)
            Text(account.pendingGoogleSignIn == nil
                ? "Google hesabını tarayıcıda seçersin; ardından Gistsmith açılır ve girişi tamamlar."
                : "Tarayıcıda Google hesabını seç; Gistsmith ardından kendiliğinden açılır. 10 dakika içinde tamamlanmazsa yeniden bas.")
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
        SettingsRow(title: Text("Oturum")) {
            Text("Bu Mac'teki oturumu kapatır; toplantıların ve notların bu Mac'te kalır.")
        } control: {
            Button("Çıkış yap") { Task { await account.signOut() } }
                .disabled(account.isWorking)
        }
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
            }
        }
        .task { await account.refresh() }
    }
}

import AINotepadCore
import AINotepadUI
import SwiftUI

/// iPhone karşılama sayfası.
private enum PhoneOnboardingPage: Int, CaseIterable {
    case welcome
    case profile
    case keys
    case ready

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Toplantılarını dinler, notunu yazar"
        case .profile: "Sana göre ayarlanır"
        case .keys: "Anahtarlar yalnız sende"
        case .ready: "Cebinde hazır"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .welcome: "Yüz yüze toplantılar canlı yazıya dökülür, Türkçesi altında akar; bitince not hazır, en üstte senin görevlerin."
        case .profile: "Adın notta sana düşen görevleri ayırır; ana dil canlı metnin hangi dille başlayacağını belirler."
        case .keys: "Mac'teki anahtarlar iCloud Anahtar Zinciri ile gelir ya da burada girersin; hiçbir yere gönderilmez."
        case .ready: "Kilit ekranında süre ve son cümle; Denetim Merkezi ya da Eylem düğmesiyle tek dokunuşla kayıt."
        }
    }

    var symbols: [String] {
        switch self {
        case .welcome: ["mic.fill", "captions.bubble.fill", "checklist"]
        case .profile: ["person.fill", "globe"]
        case .keys: ["key.fill", "icloud.fill"]
        case .ready: ["lock.iphone", "record.circle.fill", "sparkles"]
        }
    }

    var palette: FilmPalette {
        rawValue.isMultiple(of: 2) ? .sunset : .rose
    }
}

/// İlk açılış: film gradyanlı panel ve sayfanın içeriği; her sayfa atlanabilir, hepsi sonra Ayarlar'dan değişir.
/// Bitince ya da atlanınca bir daha gösterilmez.
struct PhoneOnboarding: View {
    let onOpenSettings: @MainActor () -> Void
    let onFinish: @MainActor () -> Void
    @State private var page: PhoneOnboardingPage = launchOnboardingPage(arguments: CommandLine.arguments)
    @AppStorage(PhoneSettingsKey.userName) private var userName: String = ""
    @AppStorage(PhoneSettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue

    var body: some View {
        VStack(spacing: 20) {
            OnboardingPanel(
                palette: page.palette, seed: "iphone-\(page.rawValue)", symbols: page.symbols, title: page.title,
                subtitle: page.subtitle, stepIndex: page.rawValue, stepCount: PhoneOnboardingPage.allCases.count
            )
            .frame(maxHeight: 400)
            Group {
                switch page {
                case .welcome:
                    VStack(spacing: 10) {
                        FeatureTile(symbol: "captions.bubble.fill", title: "Canlı metin ve çeviri", text: "35 dil; konuşmacılar ayrılır, Türkçesi altında akar.", palette: .sunset)
                        FeatureTile(symbol: "checklist", title: "Önce senin görevlerin", text: "Bitince not: görevler, kararlar ve özet.", palette: .rose)
                    }
                case .profile:
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Adın", text: $userName, prompt: Text("Adın (ör. Doğan)"))
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .appFont(size: 17, weight: .regular)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                        HStack {
                            Text("Ana toplantı dili").appFont(size: 15, weight: .regular)
                            Spacer()
                            Picker("Ana toplantı dili", selection: $primaryLanguage) {
                                ForEach(MeetingLanguage.allCases, id: \.rawValue) { (language: MeetingLanguage) in
                                    Text(languageName(language: language)).tag(language.rawValue)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                    }
                case .keys:
                    VStack(spacing: 10) {
                        FeatureTile(symbol: "laptopcomputer", title: "Mac'ten gönder", text: "Mac'te Ayarlar › Anahtarlar › \"iPhone'a gönder\".", palette: .sunset)
                        Button("Ya da anahtarları burada gir", systemImage: "key") {
                            onOpenSettings()
                        }
                        .appFont(size: 14, weight: .medium)
                        .padding(.top, 4)
                    }
                case .ready:
                    VStack(spacing: 10) {
                        FeatureTile(symbol: "hand.raised.fill", title: "Önce haber ver", text: "Kayıt başlarken katılımcılara söylemeyi hatırlatır.", palette: .rose)
                    }
                }
            }
            .id(page)
            .transition(.opacity.combined(with: .offset(x: 16)))
            Spacer(minLength: 0)
            HStack {
                if page == .welcome {
                    Button("Atla") { onFinish() }
                        .foregroundStyle(Theme.muted)
                } else {
                    Button("Geri", systemImage: "chevron.left") { move(by: -1) }
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button {
                    if page == .ready {
                        onFinish()
                    } else {
                        move(by: 1)
                    }
                } label: {
                    Text(page == .ready ? "Başla" : "İleri")
                        .appFont(size: 16, weight: .semibold)
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 13)
                        .background(Theme.primary, in: Capsule())
                }
                .buttonStyle(PressableCardStyle())
            }
            .appFont(size: 15, weight: .medium)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background {
            ZStack {
                Theme.background
                FlowingLines(seed: "iphone-karsilama", lineCount: 10, isAnimated: true)
            }
            .ignoresSafeArea()
        }
        .animation(.smooth(duration: 0.4), value: page)
    }

    private func move(by offset: Int) {
        page = PhoneOnboardingPage(rawValue: page.rawValue + offset) ?? page
    }
}

/// `--karsilama-sayfa <n>` (görsel kontrol): karşılama o sayfadan açılır; yoksa ilk sayfa. Saf fonksiyondur.
private func launchOnboardingPage(arguments: [String]) -> PhoneOnboardingPage {
    guard let index = arguments.firstIndex(of: "--karsilama-sayfa"), arguments.indices.contains(index + 1),
          let number = Int(arguments[index + 1]), let page = PhoneOnboardingPage(rawValue: number) else {
        return .welcome
    }
    return page
}

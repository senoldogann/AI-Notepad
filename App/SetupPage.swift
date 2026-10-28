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

    /// Sağdaki başlık.
    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Hoş geldin"
        case .permissions: "İzinler"
        case .profile: "Sen ve motor"
        case .keys: "Anahtarlar"
        case .ready: "Hazırsın"
        }
    }

    /// Yol haritasında adımın tek satırlık açıklaması.
    var roadmapDetail: LocalizedStringKey {
        switch self {
        case .welcome: "Uygulamanın yapabildikleri"
        case .permissions: "Mikrofon ve sistem sesi"
        case .profile: "Adın ve canlı metin motoru"
        case .keys: "Bulut ve Claude anahtarları"
        case .ready: "Kısayollar ve ilk kayıt"
        }
    }

    /// Soldaki film gradyanlı panelin başlığı.
    var panelTitle: LocalizedStringKey {
        switch self {
        case .welcome: "Toplantılarını dinler, notunu yazar"
        case .permissions: "İki ses, tek kayıt"
        case .profile: "Sana göre ayarlanır"
        case .keys: "Anahtarlar yalnız sende"
        case .ready: "Bir kısayol uzağında"
        }
    }

    /// Panelin kısa tanıtımı.
    var panelSubtitle: LocalizedStringKey {
        switch self {
        case .welcome: "Teams, Zoom ve yüz yüze toplantılar canlı yazıya dökülür; bitince \(selectedNoteLanguage().interfaceName) not hazır, en üstte senin görevlerin."
        case .permissions: "Mikrofon senin sesin, sistem sesi karşı taraf. İkisi ayrı kaydedilir, konuşmacılar ayrılır."
        case .profile: "Adın notta sana düşen görevleri ayırır; canlı metni bulutta ya da bu Mac'te yazdırırsın."
        case .keys: "macOS Anahtar Zinciri'nde saklanır, hiçbir yere gönderilmez; istersen iCloud ile iPhone'a gider."
        case .ready: "Kaydı kısayolla başlat; toplantı bitince notun ve görevlerin hazır."
        }
    }

    /// Paneldeki simgeler.
    var symbols: [String] {
        switch self {
        case .welcome: ["captions.bubble.fill", "waveform", "checklist"]
        case .permissions: ["mic.fill", "speaker.wave.2.fill"]
        case .profile: ["person.fill", "cloud.fill", "laptopcomputer"]
        case .keys: ["key.fill", "lock.fill"]
        case .ready: ["command", "record.circle.fill", "sparkles"]
        }
    }

    /// Panelin film gradyanı (temanın sıcak ailesi).
    var palette: FilmPalette {
        rawValue.isMultiple(of: 2) ? .sunset : .rose
    }
}

/// Kurulum (ana pencerede; ilk açılışta pencere burada açılır): izinler, ad, motor, anahtarlar; her adım atlanabilir,
/// ayarlar sonra Ayarlar'dan değişir.
struct SetupPage: View {
    let model: AppModel
    let shortcuts: ShortcutController
    let onFinish: @MainActor () -> Void
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            HStack(spacing: 32) {
                OnboardingPanel(
                    palette: step.palette, seed: "kurulum-\(step.rawValue)", symbols: step.symbols, title: step.panelTitle,
                    subtitle: step.panelSubtitle, stepIndex: step.rawValue, stepCount: OnboardingStep.allCases.count
                )
                .frame(width: min(440, geometry.size.width * 0.42))
                VStack(alignment: .leading, spacing: 18) {
                    Text(step.title)
                        .appFont(size: 30, weight: .regular)
                        .tracking(-0.6)
                        .id("baslik-\(step.rawValue)")
                        .transition(.opacity)
                    ScrollView {
                        Group {
                            switch step {
                            case .welcome: WelcomeStep()
                            case .permissions: PermissionsStep(model: model)
                            case .profile: ProfileStep(model: model)
                            case .keys: KeysStep(model: model)
                            case .ready: ReadyStep(shortcuts: shortcuts)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id(step)
                        .transition(.opacity.combined(with: .offset(x: 18)))
                    }
                    .scrollIndicators(.hidden)
                    // Yol haritası her adımda aynı yerde, düğmelerin hemen üstünde: içerik yukarıda kalır, aradaki boşluk
                    // dolar. Yer darsa önce açıklamalar, o da sığmazsa harita tümden gizlenir (kesilmez).
                    ViewThatFits(in: .vertical) {
                        SetupRoadmap(current: step, showsDetails: true) { (target: OnboardingStep) -> Void in step = target }
                        SetupRoadmap(current: step, showsDetails: false) { (target: OnboardingStep) -> Void in step = target }
                        Color.clear.frame(height: 0)
                    }
                    HStack(spacing: 12) {
                        if step != .welcome {
                            Button("Geri", systemImage: "chevron.left") { move(by: -1) }
                                .buttonStyle(.hoverPlain)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if step == .ready {
                            Button("Başla") { onFinish() }
                                .buttonStyle(.pillPrimary)
                                .keyboardShortcut(.defaultAction)
                        } else {
                            Button("Atla") { onFinish() }
                                .buttonStyle(.hoverPlain)
                                .foregroundStyle(Theme.muted)
                            Button("İleri") { move(by: 1) }
                                .buttonStyle(.pillPrimary)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .controlSize(.large)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.smooth(duration: 0.4), value: step)
    }

    private func move(by offset: Int) {
        step = OnboardingStep(rawValue: step.rawValue + offset) ?? step
    }
}

/// Kurulumun yol haritası: tüm adımlar sırayla, aralarında ince dikey çizgi. Biten adım soluk ve onaylı (tıklayınca
/// ona dönülür), şimdiki adım vurgu renginde dolu nokta ve koyu yazıyla, sıradakiler boş halka ve soluk. Durgundur;
/// yalnızca adım değişince kısa bir geçiş yapar.
private struct SetupRoadmap: View {
    let current: OnboardingStep
    let showsDetails: Bool
    let onSelect: @MainActor (OnboardingStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(OnboardingStep.allCases, id: \.self) { (item: OnboardingStep) in
                row(step: item, isLast: item == OnboardingStep.allCases.last)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.25), value: current)
    }

    @ViewBuilder
    private func row(step: OnboardingStep, isLast: Bool) -> some View {
        if step.rawValue < current.rawValue {
            Button { onSelect(step) } label: {
                rowContent(step: step, isLast: isLast)
            }
            .buttonStyle(.plain)
            .linkPointer(isEnabled: true)
            .accessibilityHint(Text("Bu adıma dön"))
        } else {
            rowContent(step: step, isLast: isLast)
                .accessibilityAddTraits(step == current ? [.isSelected] : [])
        }
    }

    private func rowContent(step: OnboardingStep, isLast: Bool) -> some View {
        let isCurrent: Bool = step == current
        return HStack(alignment: .top, spacing: 12) {
            RoadmapMarker(state: roadmapMarkerState(step: step, current: current))
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .appFont(size: 13, weight: isCurrent ? .medium : .regular)
                    .foregroundStyle(isCurrent ? Theme.ink : Theme.muted)
                    .lineLimit(1)
                if showsDetails {
                    Text(step.roadmapDetail)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            .padding(.bottom, isLast ? 0 : 12)
            Spacer(minLength: 0)
        }
        // Noktaları birleştiren çizgi: bu noktanın altından bir sonrakinin tepesine.
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(Theme.line)
                    .frame(width: 1)
                    .padding(.top, roadmapMarkerSize + 2)
                    .padding(.bottom, 2)
                    .padding(.leading, roadmapMarkerSize / 2 - 0.5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Yol haritası noktasının çapı.
private let roadmapMarkerSize: CGFloat = 18

/// Yol haritasındaki adımın durumu.
private enum RoadmapMarkerState {
    case done
    case current
    case upcoming
}

/// Adımın şimdiki adıma göre durumu. Saf fonksiyondur.
private func roadmapMarkerState(step: OnboardingStep, current: OnboardingStep) -> RoadmapMarkerState {
    if step == current {
        return .current
    }
    return step.rawValue < current.rawValue ? .done : .upcoming
}

/// Yol haritasının noktası: biten adımda onay, şimdikinde vurgu renginde dolu nokta, sıradakinde boş halka.
private struct RoadmapMarker: View {
    let state: RoadmapMarkerState
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Theme.soft)
                Circle().strokeBorder(Theme.line)
                Image(systemName: "checkmark")
                    .appFont(size: 8, weight: .bold)
                    .foregroundStyle(Theme.muted)
            case .current:
                Circle().strokeBorder(appearance.accent.color, lineWidth: 1.5)
                Circle().fill(appearance.accent.color).padding(4.5)
            case .upcoming:
                Circle().strokeBorder(Theme.line, lineWidth: 1.5)
            }
        }
        .frame(width: roadmapMarkerSize, height: roadmapMarkerSize)
        .accessibilityHidden(true)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        // Not ve çeviri dilinin adı (kurulumda varsayılanı: arayüz dili).
        let noteLanguageName: String = selectedNoteLanguage().interfaceName
        VStack(alignment: .leading, spacing: 16) {
            Text("Birkaç adımda hazırsın; her adım atlanabilir, hepsi sonra Ayarlar'dan değişir.")
                .appFont(size: 14, weight: .regular)
                .foregroundStyle(Theme.muted)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                FeatureTile(symbol: "captions.bubble.fill", title: "Canlı metin ve çeviri", text: "Fince, İngilizce ve 33 dil daha; \(noteLanguageName) çevirisi altında akar.", palette: .sunset)
                FeatureTile(symbol: "sparkles", title: "Ne kaçırdım?", text: "Son dakikaların \(noteLanguageName) özeti, toplantıya soru.", palette: .rose)
                FeatureTile(symbol: "checklist", title: "Önce senin görevlerin", text: "Bitince not: görevler, kararlar, özet ve sözlük.", palette: .rose)
                FeatureTile(symbol: "eye.slash.fill", title: "Ekran paylaşımında gizli", text: "Panel ve ada paylaşılan ekranda görünmez.", palette: .sunset)
            }
        }
    }
}

/// Mikrofon ve sistem sesi izinleri.
private struct PermissionsStep: View {
    let model: AppModel
    @State private var microphone: AVAudioApplication.recordPermission = .undetermined
    @State private var systemAudio: ProbeState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .pointerStyle(.link)
            }
            .appFont(size: 12, weight: .regular)
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
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .appFont(size: 17, weight: .medium)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).appFont(size: 14, weight: .semibold)
                Text(detail).appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted)
                Label(status, systemImage: isGranted ? "checkmark.circle.fill" : "circle.dotted")
                    .appFont(size: 11, weight: .medium)
                    .foregroundStyle(isGranted ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
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

/// Ad, başlama yolu (cihaz içi ya da kendi anahtarlarınla) ve canlı metin motoru.
private struct ProfileStep: View {
    let model: AppModel
    @AppStorage(SettingsKey.userName) private var userName: String = ""
    @AppStorage(SettingsKey.llmProvider) private var provider: String = LLMProviderKind.anthropic.rawValue
    @AppStorage(SettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(SettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Adın").appFont(size: 13, weight: .semibold)
                TextField("Adın", text: $userName, prompt: Text("ör. Doğan"))
                    .textFieldStyle(.plain)
                    .appFont(size: 16, weight: .regular)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                Text("Notta sana düşen görevler bu adla ayrılır.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Nasıl başlamak istersin?").appFont(size: 13, weight: .semibold)
                HStack(alignment: .top, spacing: 12) {
                    ChoiceCard(
                        symbol: "cpu", title: "Hemen başla (cihaz içi)",
                        text: "Ücretsiz, anahtarsız: yazıya dökme ve not Apple Intelligence ile bu Mac'te. Konuşmacılar ayrılmaz, not daha kısadır.",
                        isSelected: isOnDevice
                    ) {
                        provider = LLMProviderKind.onDevice.rawValue
                        Task { await model.selectEngine(engine: .appleSpeech) }
                    }
                    ChoiceCard(
                        symbol: "key.fill", title: "Kendi anahtarlarımla",
                        text: "Daha yüksek kalite: Claude ile not, konuşmacılar ayrılır. Sonraki adımda anahtarları girersin.",
                        isSelected: !isOnDevice
                    ) {
                        provider = LLMProviderKind.anthropic.rawValue
                        Task { await model.selectEngine(engine: .deepgram) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if isOnDevice {
                    // Cihaz içi tanıma dil algılamaz ve model her dili yazamaz: toplantıların dili burada seçilir.
                    HStack(spacing: 10) {
                        Text("Ana toplantı dili").appFont(size: 13, weight: .regular)
                        Spacer(minLength: 8)
                        SettingsMenu(selection: $primaryLanguage, options: MeetingLanguage.allCases.map { (language: MeetingLanguage) -> (String, Text) in
                            (language.rawValue, Text(verbatim: languageName(language: language)))
                        })
                    }
                    .padding(.top, 4)
                    .onChange(of: primaryLanguage) { (_: String, _: String) in
                        model.primaryLanguageChanged()
                    }
                }
                if isOnDevice, let problem = onDeviceProblem {
                    Text(verbatim: problem)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !isOnDevice {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Canlı metin").appFont(size: 13, weight: .semibold)
                    HStack(alignment: .top, spacing: 12) {
                        ChoiceCard(
                            symbol: "cloud.fill", title: "Bulut (en hızlı)",
                            text: "Deepgram ve ElevenLabs; konuşmacılar canlı ayrılır. İki anahtar gerekir.",
                            isSelected: model.liveEngine == .deepgram
                        ) {
                            Task { await model.selectEngine(engine: .deepgram) }
                        }
                        ChoiceCard(
                            symbol: "laptopcomputer", title: "Bu Mac'te",
                            text: "WhisperKit, internetsiz. İlk açılışta ~630 MB model indirilir.",
                            isSelected: model.liveEngine == .whisperKit
                        ) {
                            Task { await model.selectEngine(engine: .whisperKit) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Cihaz içi mod seçili: Apple konuşma tanıma ve Apple Intelligence.
    private var isOnDevice: Bool {
        model.liveEngine == .appleSpeech && provider == LLMProviderKind.onDevice.rawValue
    }

    /// Cihaz içi model kullanılamıyorsa nedeni ve ne yapılacağı; kullanılabiliyorsa nil.
    private var onDeviceProblem: String? {
        do {
            let config: OnDeviceConfig = try onDeviceConfig()
            return onDeviceModeWarning(config: config, primaryLanguage: primaryMeetingLanguage(), outputLanguage: storedNoteLanguage(value: noteLanguage))
        } catch {
            return userFacingMessage(error: error)
        }
    }
}

/// Seçili motorun ve LLM'in anahtarları.
private struct KeysStep: View {
    let model: AppModel
    @AppStorage(SettingsKey.llmProvider) private var provider: String = LLMProviderKind.anthropic.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if provider == LLMProviderKind.onDevice.rawValue, model.liveEngine == .appleSpeech {
                Text("Cihaz içi modda anahtar gerekmez; bu adımı atlayabilirsin. Daha yüksek kalite istersen anahtarları sonra Ayarlar'dan ekleyip sağlayıcıyı değiştirirsin.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if model.liveEngine == .deepgram {
                    SecretField(title: "Deepgram", account: .deepgram, onChange: model.settingsChanged)
                    SecretField(title: "ElevenLabs", account: .elevenlabs, onChange: model.settingsChanged)
                }
                SecretField(title: "Anthropic (Claude)", account: .anthropic, onChange: model.settingsChanged)
                LocalLLMSetup(model: model)
                Text("Çeviri, özet ve not için Claude kullanılır; anahtarsız istersen Mac'teki Ollama'yı seç. OpenAI ve OpenCode Go Ayarlar › LLM'de.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
    }
}

/// Kısayollar ve ilk kullanım.
private struct ReadyStep: View {
    let shortcuts: ShortcutController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ShortcutAction.allCases, id: \.self) { (action: ShortcutAction) in
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        ForEach(Array(keyBindingDisplay(binding: shortcuts.currentBinding(action: action)).map(String.init).enumerated()), id: \.offset) { (key: (offset: Int, element: String)) in
                            Text(verbatim: key.element)
                                .appFont(size: 15, weight: .medium)
                                .frame(minWidth: 30, minHeight: 30)
                                .padding(.horizontal, 4)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                                .shadow(color: .black.opacity(0.08), radius: 0, y: 2)
                        }
                    }
                    Text(action.title).appFont(size: 14, weight: .regular)
                    Spacer(minLength: 0)
                }
            }
            FeatureTile(
                symbol: "rectangle.on.rectangle", title: "Kayıt sırasında cam panel",
                text: "Canlı metin ve \(selectedNoteLanguage().interfaceName) çevirisi, \"Ne kaçırdım?\" ve soru; çentikte ada süreyi ve son cümleyi gösterir.", palette: .sunset
            )
            .padding(.top, 6)
            FeatureTile(
                symbol: "checklist", title: "Bitince toplantının sayfası",
                text: "En üstte senin görevlerin; özet, kararlar, konuşmacılı transkript ve çalma.", palette: .rose
            )
        }
    }
}

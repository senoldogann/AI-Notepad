import AINotepadCore
import AINotepadUI
import AppKit
import AuthenticationServices
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os

/// Ayarlar bölümleri.
/// `--ayar genel|gorunum|llm|anahtarlar|kisayollar` başlatma argümanından açılacak sekme (görsel kontrol için); yoksa
/// genel. Saf fonksiyondur.
private func launchSettingsSection(arguments: [String]) -> SettingsSection {
    guard let index = arguments.firstIndex(of: "--ayar"), arguments.indices.contains(index + 1) else {
        return .general
    }
    switch arguments[index + 1] {
    case "gorunum": return .appearance
    case "llm": return .llm
    case "anahtarlar": return .keys
    case "baglantilar": return .connections
    case "kisayollar": return .shortcuts
    default: return .general
    }
}

private enum SettingsSection: CaseIterable {
    case general
    case appearance
    case llm
    case keys
    case connections
    case shortcuts

    var title: LocalizedStringKey {
        switch self {
        case .general: "Genel"
        case .appearance: "Görünüm"
        case .llm: "LLM"
        case .keys: "Anahtarlar"
        case .connections: "Bağlantılar"
        case .shortcuts: "Kısayollar"
        }
    }
}

/// Ana penceredeki Ayarlar (ElevenLabs düzeni): büyük başlık, altı çizili sekmeler; her ayar ince çizgiyle ayrılmış bir
/// satır (solda başlık ve açıklama, sağda denetim).
struct SettingsPage: View {
    let model: AppModel
    let shortcuts: ShortcutController
    /// Karşılama ve kurulum ekranını yeniden açar.
    let onShowSetup: @MainActor () -> Void
    @State private var section: SettingsSection = launchSettingsSection(arguments: CommandLine.arguments)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Ayarlar")
                    .appFont(size: 30, weight: .regular)
                    .tracking(-0.5)
                Text("Arayüz dilini, tanıma motorunu, görünümü, yapay zekâ modellerini, anahtarları ve kısayolları yönet.")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
                SettingsTabs(selection: $section)
                    .padding(.top, 20)
                Group {
                    switch section {
                    case .general: GeneralSettings(model: model, onShowSetup: onShowSetup)
                    case .appearance: AppearanceSettings()
                    case .llm: LLMSettings(model: model)
                    case .keys: KeySettings(model: model)
                    case .connections: ConnectionSettings(model: model)
                    case .shortcuts: ShortcutSettings(shortcuts: shortcuts)
                    }
                }
                .id(section)
                .transition(.opacity)
                .padding(.top, 8)
            }
            .animation(.smooth(duration: 0.2), value: section)
            // Geniş pencerede form satırları ekran boyu uzamasın; kaydırma alanı tam genişlikte.
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Altı çizili sekmeler: seçili sekme ince çerçeveli kutu, altında çizginin üstünde koyu çizgi; geçiş kayarak.
private struct SettingsTabs: View {
    @Binding var selection: SettingsSection
    @Namespace private var marker

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsSection.allCases, id: \.self) { (item: SettingsSection) in
                    let isSelected: Bool = item == selection
                    Button {
                        selection = item
                    } label: {
                        Text(item.title)
                            .appFont(size: 14, weight: isSelected ? .medium : .regular)
                            .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Theme.card)
                                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
                                        .matchedGeometryEffect(id: "box", in: marker)
                                }
                            }
                    }
                    .buttonStyle(.hoverPlain)
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Rectangle()
                                .fill(Theme.ink)
                                .frame(height: 2)
                                .offset(y: 9)
                                .matchedGeometryEffect(id: "line", in: marker)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .animation(.smooth(duration: 0.25), value: selection)
    }
}

/// Motor, ad, canlı çeviri, mikrofon, "Ne kaçırdım?" süresi ve ses saklama süresi.
private struct GeneralSettings: View {
    let model: AppModel
    let onShowSetup: @MainActor () -> Void
    @AppStorage(SettingsKey.userName) private var userName: String = ""
    @AppStorage(SettingsKey.missedWindowMinutes) private var missedMinutes: Int = 3
    @AppStorage(SettingsKey.audioRetentionDays) private var retentionDays: Int = 30
    @AppStorage(SettingsKey.voiceRecognition) private var voiceRecognition: Bool = false
    @AppStorage(SettingsKey.consentReminder) private var consentReminder: Bool = true
    @AppStorage(SettingsKey.calendarEnabled) private var calendarEnabled: Bool = false
    @AppStorage(SettingsKey.customVocabulary) private var vocabulary: String = ""
    @AppStorage(SettingsKey.meetingReminders) private var meetingReminders: Bool = true
    @AppStorage(SettingsKey.micSuggestions) private var micSuggestions: Bool = true
    @AppStorage(SettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(SettingsKey.autoRecord) private var autoRecord: Bool = false
    @AppStorage(SettingsKey.noteTemplate) private var noteTemplate: String = NoteTemplateKind.general.rawValue
    @AppStorage(SettingsKey.customTemplate) private var customTemplate: String = ""
    @State private var interfaceLanguage: InterfaceLanguage = storedInterfaceLanguage()
    @State private var relaunchError: String?

    var body: some View {
        // Kayıt ya da toplantı işleme sürerken yeniden başlatılırsa o toplantı yarıda kalır.
        let isBusy: Bool = model.isBusy
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: Text("Arayüz dili")) {
                Text("Toplantı notları ve canlı çeviri her zaman Türkçedir.")
                if interfaceLanguage != launchInterfaceLanguage {
                    Text("Yeniden başlatınca uygulanır.").foregroundStyle(Theme.ink)
                }
                if let relaunchError {
                    Text(relaunchError).foregroundStyle(.red)
                }
            } control: {
                HStack(spacing: 8) {
                    if interfaceLanguage != launchInterfaceLanguage {
                        Button("Şimdi yeniden başlat") {
                            do {
                                try relaunchApplication()
                            } catch {
                                relaunchError = String(localized: "Yeniden başlatılamadı: \(error.localizedDescription)")
                            }
                        }
                        .disabled(isBusy)
                        .hoverHint(isBusy ? "Kayıt ve işleme bitince yeniden başlatılabilir" : "Uygulamayı yeni dille yeniden açar", alignment: .trailing, edge: .bottom)
                    }
                    SettingsMenu(selection: $interfaceLanguage, options: [
                        (InterfaceLanguage.system, Text("Sistem")),
                        (InterfaceLanguage.turkish, Text(verbatim: "Türkçe")),
                        (InterfaceLanguage.english, Text(verbatim: "English")),
                    ])
                }
            }
            .onChange(of: interfaceLanguage) { (_: InterfaceLanguage, language: InterfaceLanguage) in
                storeInterfaceLanguage(language: language)
            }
            SettingsRow(title: Text("Canlı metin")) {
                switch model.liveEngine {
                case .deepgram: Text("Konuşmacılar ElevenLabs ile dakikada bir ayrılır; kayıt bitince ElevenLabs son geçişi yapılır.")
                case .whisperKit: Text("Ses Mac'ten çıkmaz; kayıt bitince konuşmacılar Mac'te (SpeakerKit) ayrılır. Not için LLM gerekir.")
                case .appleSpeech: Text("Apple'ın konuşma tanıması; ses Mac'ten çıkmaz, anahtar ve büyük model indirmesi gerekmez. Dil algılanmaz (ana toplantı diliyle başlar), konuşmacılar ayrılmaz.")
                }
            } control: {
                SettingsMenu(selection: Binding<LiveEngine>(
                    get: { model.liveEngine },
                    set: { (engine: LiveEngine) -> Void in
                        Task { await model.selectEngine(engine: engine) }
                    }
                ), options: [
                    (LiveEngine.appleSpeech, Text("Cihaz içi (ücretsiz, anahtarsız)")),
                    (LiveEngine.deepgram, Text("Deepgram (bulut, ~1 sn)")),
                    (LiveEngine.whisperKit, Text("Mac'te (WhisperKit, internetsiz)")),
                ])
                .disabled(model.isRecording)
            }
            SettingsRow(title: Text("Ana toplantı dili")) {
                Text("Otomatik dilde kayıt bu dille başlar; ilk dakikada konuşulan dil (35 dil) bulunup ona geçilir. Mac'te tanımada bu dil ile İngilizce arasında seçilir.")
            } control: {
                SettingsMenu(selection: $primaryLanguage, options: MeetingLanguage.allCases.map { (language: MeetingLanguage) -> (String, Text) in
                    (language.rawValue, Text(verbatim: languageName(language: language)))
                })
            }
            SettingsRow(title: Text("Kurulum")) {
                Text("İzinler, anahtarlar ve kısayollar adım adım.")
            } control: {
                Button("Kurulumu yeniden aç") { onShowSetup() }
            }
            SettingsRow(title: Text("Adın")) {
                Text("Toplantı notunda sana düşen görevleri ayırmak için kullanılır.")
            } control: {
                TextField("Adın", text: $userName)
                    .settingsField(width: 200)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tanıma sözlüğü").appFont(size: 15, weight: .medium)
                Text("Konuşma tanımanın doğru yazması gereken adlar, şirket ve ürün adları, kısaltmalar; satır başına bir tane (2–40 karakter, en fazla 5 sözcük; en fazla 30 kullanılır). Bulut motorunda (Deepgram, ElevenLabs) uygulanır. Toplantılarda verdiğin konuşmacı adları ve sözlük terimleri zaten kendiliğinden eklenir.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $vocabulary)
                    .appFont(size: 13, weight: .regular)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 80)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                Text("\(customVocabulary(text: vocabulary).count) terim")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 16)
            SettingsDivider()
            SettingsRow(title: Text("Takvimi kullan")) {
                Text("Yaklaşan toplantılar Ana sayfada görünür; kayıt o anki toplantıya bağlanır: başlığı ve katılımcı adları (tanıma ve konuşmacı adı ipucu) kayda geçer. Takvim yalnızca bu Mac'te okunur.")
                if let error = model.calendarError {
                    Text(error).foregroundStyle(.red)
                }
            } control: {
                Toggle("Takvimi kullan", isOn: Binding<Bool>(
                    get: { calendarEnabled },
                    set: { (enabled: Bool) -> Void in
                        if enabled {
                            Task { await model.enableCalendar() }
                        } else {
                            model.disableCalendar()
                        }
                    }
                ))
                .settingsToggle()
            }
            if calendarEnabled {
                SettingsRow(title: Text("Toplantıdan 1 dk önce hatırlat")) {
                    Text("Bildirimdeki \"Dinlemeye başla\" ile kayıt hemen başlar.")
                    if let problem = model.notificationProblem {
                        Text(problem).foregroundStyle(.orange)
                    }
                } control: {
                    Toggle("Toplantıdan 1 dk önce hatırlat", isOn: $meetingReminders)
                        .settingsToggle()
                        .onChange(of: meetingReminders) { (_: Bool, _: Bool) in model.startCalendarServices() }
                }
                SettingsRow(title: Text("Görüşme başlayınca öner")) {
                    Text("Teams, Zoom ya da başka bir uygulama mikrofonu açınca (kayıt yoksa) dinlemeye başlamayı önerir; 10 dk'da en fazla bir kez.")
                } control: {
                    Toggle("Görüşme başlayınca öner", isOn: $micSuggestions)
                        .settingsToggle()
                        .onChange(of: micSuggestions) { (_: Bool, _: Bool) in model.startCalendarServices() }
                }
                SettingsRow(title: Text("Takvimdeki görüşmeleri kendiliğinden kaydet")) {
                    Text("Takvimde görüşme bağlantısı (Teams, Zoom, Meet) olan bir toplantı sürerken başka bir uygulama mikrofonu açınca kayıt kendiliğinden başlar ve bildirilir; bir kez kur, unut. Katılımcılara kaydettiğini söylemek senin sorumluluğunda.")
                } control: {
                    Toggle("Takvimdeki görüşmeleri kendiliğinden kaydet", isOn: $autoRecord)
                        .settingsToggle()
                        .onChange(of: autoRecord) { (_: Bool, _: Bool) in model.startCalendarServices() }
                }
            }
            SettingsRow(title: Text("Not şablonu")) {
                Text("Yeni toplantıların notu bu türe göre yazılır; bir toplantının notunu sonradan başka şablonla yeniden yazabilirsin (⋯ menüsü).")
            } control: {
                SettingsMenu(selection: $noteTemplate, options: NoteTemplateKind.allCases.map { (kind: NoteTemplateKind) -> (String, Text) in
                    (kind.rawValue, Text(templateTitle(kind: kind)))
                })
            }
            if noteTemplate == NoteTemplateKind.custom.rawValue {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kendi şablonun: notta neyin öne çıkmasını istediğini yaz")
                        .appFont(size: 13, weight: .medium)
                    TextEditor(text: $customTemplate)
                        .appFont(size: 13, weight: .regular)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 90)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
                    Text("Örnek: \"Riskleri ayrı bir paragrafta say, her kararın gerekçesini yaz.\"")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 12)
                SettingsDivider()
            }
            SettingsRow(title: Text("Kayıt sırasında Türkçeye çevir")) {
                Text(model.displayMode.needsLiveTranslation
                    ? "Her cümle kayıt sırasında çevrilir (LLM çağrısı). Toplantı bitince Türkçe not (görevler, kararlar, özet) hazırlanır."
                    : "Kayıt sırasında çeviri yapılmaz, yalnızca orijinal metin görünür. Toplantı bitince Türkçe not (görevler, kararlar, özet) yine hazırlanır.")
            } control: {
                Toggle("Kayıt sırasında Türkçeye çevir", isOn: Binding<Bool>(
                    get: { model.displayMode.needsLiveTranslation },
                    set: { (enabled: Bool) -> Void in model.selectDisplayMode(mode: enabled ? .bilingual : .originalOnly) }
                ))
                .settingsToggle()
            }
            if model.displayMode.needsLiveTranslation {
                SettingsRow(title: Text("Gösterim")) {
                    EmptyView()
                } control: {
                    SettingsMenu(selection: Binding<DisplayMode>(
                        get: { model.displayMode },
                        set: { (mode: DisplayMode) -> Void in model.selectDisplayMode(mode: mode) }
                    ), options: [
                        (DisplayMode.bilingual, Text("İki dil (orijinal + Türkçe)")),
                        (DisplayMode.turkishOnly, Text("Sadece Türkçe")),
                    ])
                }
            }
            SettingsRow(title: Text("Kendi sesimi de kaydet (mikrofon)")) {
                Text("Kapalıyken yalnızca bilgisayardan gelen ses (karşı taraf) kaydedilir: mikrofon hiç açılmaz, hoparlör yankısı \"Sen\" diye yazılmaz. Paneldeki mikrofon düğmesiyle kayıttan önce de seçilebilir; mikrofonla başlayan kayıtta düğme yalnızca susturur. Yüz yüze modunda mikrofon her zaman açıktır (odadaki herkesi kaydeder).")
            } control: {
                Toggle("Kendi sesimi de kaydet (mikrofon)", isOn: Binding<Bool>(
                    get: { !model.isMicMuted },
                    set: { (enabled: Bool) -> Void in
                        if enabled == model.isMicMuted {
                            model.toggleMicrophone()
                        }
                    }
                ))
                .settingsToggle()
            }
            SettingsRow(title: Text("Kayıt başlarken haber vermeyi hatırlat")) {
                Text("Panelde kısa bir hatırlatma ve toplantı sohbetine yapıştırılacak Fince/İngilizce bildirim. Kayıt yapmadan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur.")
            } control: {
                Toggle("Kayıt başlarken haber vermeyi hatırlat", isOn: $consentReminder).settingsToggle()
            }
            SettingsRow(title: Text("Konuşmacıları sesinden tanı")) {
                Text("Açıkken 8 sn'den fazla konuşan herkesin ses izi (sesi tanıyan sayılar; biyometrik veridir) o toplantıyla saklanır; ad verdiğin kişininki bu Mac'te hatırlanır ve sonraki toplantılarda adı kendiliğinden gelir. Toplantı silinince ondan öğrenilen izler, sesi silinince toplantıdaki izler de silinir. Başkalarının ses izini saklamadan önce onaylarını al.")
                if let error = model.voiceRegistryError {
                    Text(error).foregroundStyle(.red)
                }
            } control: {
                Toggle("Konuşmacıları sesinden tanı", isOn: $voiceRecognition).settingsToggle()
            }
            if voiceRecognition, !model.registeredVoices.isEmpty {
                SettingsGroupHeader(title: "Tanınan sesler")
                ForEach(model.registeredVoices, id: \.name) { (voice: RegisteredVoice) in
                    SettingsRow(title: Text(voice.name)) {
                        Text("\(max(1, Int((voice.voiceprint.seconds / 60).rounded()))) dk konuşmadan · \(voice.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale())))")
                    } control: {
                        Button("Unut", role: .destructive) { model.forgetVoice(name: voice.name) }
                            .hoverHint("Bu kişi bundan sonra sesinden tanınmaz", alignment: .trailing, edge: .bottom)
                    }
                }
                SettingsDivider().opacity(0)
                    .padding(.bottom, 16)
            }
            SettingsRow(title: Text("\"Ne kaçırdım?\" son \(missedMinutes) dakikayı özetler")) {
                EmptyView()
            } control: {
                Stepper("\"Ne kaçırdım?\" son \(missedMinutes) dakikayı özetler", value: $missedMinutes, in: SettingsRange.missedWindowMinutes)
                    .labelsHidden()
            }
            SettingsRow(title: Text("Sesleri sakla")) {
                Text("Süre dolunca ses dosyaları silinir; metin ve not kalır.")
            } control: {
                SettingsMenu(selection: $retentionDays, options: [7, 14, 30, 60, 90, 180, 365].map { (days: Int) -> (Int, Text) in
                    (days, Text("\(days) gün"))
                })
            }
            .onChange(of: retentionDays) { (_: Int, _: Int) in
                model.applyRetention()
            }
            CloudSyncRow(model: model)
        }
    }
}

/// Anahtar hesabının arayüz adı. Saf fonksiyondur.
private func secretAccountTitle(account: SecretAccount) -> String {
    switch account {
    case .deepgram: "Deepgram"
    case .elevenlabs: "ElevenLabs"
    case .anthropic: "Anthropic"
    case .openai: String(localized: "OpenAI uyumlu")
    case .webhook: "Webhook"
    case .channel: String(localized: "Kanal bağlantısı")
    case .destinations: String(localized: "Kanal bağlantıları")
    case .taskTrackers: String(localized: "Görev araçları")
    }
}

/// iCloud ile eşitle: biten toplantılar iCloud Drive'a taşınır, iPhone uygulamasıyla ortak görünür; kapatınca geri
/// bu Mac'e taşınır. İş sürerken ve hata olunca durum satırda görünür.
private struct CloudSyncRow: View {
    let model: AppModel

    var body: some View {
        SettingsRow(title: Text("iCloud ile eşitle")) {
            Text("Biten toplantılar iCloud Drive'a taşınır ve iPhone'daki AI-Notepad'de de görünür; iPhone'da kaydedilenler buraya gelir. Kayıt ve işleme her zaman bu Mac'te yapılır. Kapatınca iCloud'daki toplantıların bir kopyası bu Mac'te kalır; iPhone'dakiler etkilenmez.")
            switch model.cloud.state {
            case .working:
                Text("Toplantılar taşınıyor…").foregroundStyle(Theme.ink)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            case .idle:
                if model.cloudDownloadingCount > 0 {
                    Text("\(model.cloudDownloadingCount) toplantı iCloud'dan iniyor…").foregroundStyle(Theme.ink)
                }
            }
        } control: {
            Toggle("iCloud ile eşitle", isOn: Binding<Bool>(
                get: { model.cloud.location == .iCloud },
                set: { (enabled: Bool) -> Void in
                    Task { await model.setCloudSync(enabled: enabled) }
                }
            ))
            .settingsToggle()
            .disabled(model.cloud.state == .working || model.isBusy)
        }
    }
}

/// Yazı tipi menüsünün seçenekleri: gömülü Inter ve SF tasarımları, bu Mac'te bulunan seçkin aileler; şu an seçili
/// yüklü aile listede yoksa o da eklenir (menü seçimi gösterebilsin).
@MainActor
private func fontOptions(current: String) -> [(String, Text)] {
    let builtIn: [(String, Text)] = [
        (AppFontChoice.design(.inter).storageValue, Text("Inter (varsayılan)")),
        (AppFontChoice.design(.system).storageValue, Text("Sistem (SF Pro)")),
        (AppFontChoice.design(.rounded).storageValue, Text("Yuvarlak (SF Rounded)")),
        (AppFontChoice.design(.serif).storageValue, Text("Tırnaklı (New York)")),
        (AppFontChoice.design(.monospaced).storageValue, Text("Eş aralıklı (SF Mono)")),
    ]
    let available: Set<String> = Set(NSFontManager.shared.availableFontFamilies)
    let curated: [String] = ["Avenir Next", "Helvetica Neue", "Futura", "Gill Sans", "Optima", "Charter", "Iowan Old Style", "Georgia", "Palatino", "Baskerville", "Menlo"]
        .filter { available.contains($0) }
    let selectedFamily: [String] = if case .installed(let family) = AppFontChoice.parse(storage: current), !curated.contains(family) { [family] } else { [] }
    return builtIn + (curated + selectedFamily).map { (family: String) -> (String, Text) in
        (AppFontChoice.installed(family: family).storageValue, Text(verbatim: family).font(.custom(family, size: 13)))
    }
}

/// Görünüm: tema, vurgu rengi, yazı tipi, arayüz boyutu, metin boyutu, satır aralığı, alt boşluk, ada. Değişiklikler anında görünür.
private struct AppearanceSettings: View {
    @AppStorage(SettingsKey.theme) private var theme: String = AppTheme.light.rawValue
    @AppStorage(SettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(SettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontChoice.storageValue
    @AppStorage(SettingsKey.uiScale) private var uiScale: Double = PanelAppearance.standard.uiScale
    @AppStorage(SettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(SettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @AppStorage(SettingsKey.bottomSpacing) private var bottomSpacing: Double = PanelAppearance.standard.bottomSpacing
    @AppStorage(SettingsKey.islandEnabled) private var islandEnabled: Bool = true
    @AppStorage(SettingsKey.surface) private var surface: String = PanelAppearance.standard.surface.rawValue
    @AppStorage(SettingsKey.surfaceOpacity) private var surfaceOpacity: Double = PanelAppearance.standard.surfaceOpacity
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tema")
                .appFont(size: 14, weight: .medium)
                .padding(.top, 14)
                .padding(.bottom, 10)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(AppTheme.allCases, id: \.self) { (item: AppTheme) in
                    ThemeSwatch(theme: item, isSelected: theme == item.rawValue, accent: appearance.accent.color) { theme = item.rawValue }
                }
            }
            .padding(.bottom, 14)
            SettingsDivider()
            SettingsRow(title: Text("Yüzey")) {
                Text("Cam yüzeyde masaüstü pencerenin ardından hafifçe görünür.")
            } control: {
                PillPicker(selection: $surface, options: [
                    (WindowSurface.solid.rawValue, "Dolu"), (WindowSurface.frosted.rawValue, "Buzlu cam"), (WindowSurface.clear.rawValue, "Şeffaf cam"),
                ])
                .fixedSize()
            }
            if surface != WindowSurface.solid.rawValue {
                SettingsRow(title: Text("Cam opaklığı: %\(Int((surfaceOpacity * 100).rounded()))")) {
                    EmptyView()
                } control: {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.dotted").foregroundStyle(Theme.muted)
                        Slider(value: $surfaceOpacity, in: SettingsRange.surfaceOpacity, step: 0.05).frame(width: 200)
                        Image(systemName: "circle.fill").foregroundStyle(Theme.muted)
                    }
                }
            }

            SettingsRow(title: Text("Vurgu rengi")) {
                EmptyView()
            } control: {
                SettingsMenu(selection: $accent, options: PanelAccent.allCases.map { (item: PanelAccent) -> (String, Text) in
                    (item.rawValue, Text(Image(systemName: "circle.fill")).foregroundColor(item.color) + Text(verbatim: "  ") + Text(accentName(accent: item)))
                })
            }
            SettingsRow(title: Text("Yazı tipi")) {
                Text("Uygulamanın tamamında; Mac'te yüklü her yazı tipi seçilebilir.")
            } control: {
                HStack(spacing: 8) {
                    SettingsMenu(selection: $fontDesign, options: fontOptions(current: fontDesign))
                    Menu {
                        ForEach(NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }, id: \.self) { (family: String) in
                            Button(family) { fontDesign = AppFontChoice.installed(family: family).storageValue }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.pill)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .hoverHint("Tüm yüklü yazı tipleri", alignment: .trailing, edge: .bottom)
                }
            }
            SettingsRow(title: Text("Arayüz boyutu: \(Int((uiScale * 100).rounded()))%")) {
                Text("Menüler, başlıklar ve düğmeler dahil tüm yazılar.")
            } control: {
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(Theme.muted)
                    Slider(value: $uiScale, in: SettingsRange.uiScale, step: 0.05).frame(width: 200)
                    Image(systemName: "textformat.size.larger").foregroundStyle(Theme.muted)
                }
            }
            SettingsRow(title: Text("Metin boyutu: \(Int(textSize)) pt")) {
                EmptyView()
            } control: {
                Slider(value: $textSize, in: SettingsRange.textSize, step: 1).frame(width: 240)
            }
            SettingsRow(title: Text("Satır aralığı: \(Int(lineSpacing))")) {
                EmptyView()
            } control: {
                Slider(value: $lineSpacing, in: SettingsRange.lineSpacing, step: 1).frame(width: 240)
            }
            SettingsRow(title: Text("Alt boşluk: \(Int(bottomSpacing)) pt")) {
                EmptyView()
            } control: {
                Slider(value: $bottomSpacing, in: SettingsRange.bottomSpacing, step: 4).frame(width: 240)
            }
            // Önizleme seçilen yazı tipi ve boyutla.
            VStack(alignment: .leading, spacing: 4) {
                Text("Hyvää huomenta kaikille, aloitetaan palaveri.")
                    .font(appearance.secondaryFont)
                    .opacity(0.6)
                Text("Herkese günaydın, toplantıya başlayalım.")
                    .font(appearance.bodyFont)
            }
            .lineSpacing(appearance.lineSpacing)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: 12)
            .padding(.vertical, 16)
            SettingsDivider()
            SettingsRow(title: Text("Kayıt sırasında çentikte adayı göster")) {
                EmptyView()
            } control: {
                Toggle("Kayıt sırasında çentikte adayı göster", isOn: $islandEnabled).settingsToggle()
            }
            SettingsRow(title: Text("Varsayılan görünüm")) {
                EmptyView()
            } control: {
                Button("Görünümü varsayılana döndür") {
                    resetAppearanceSettings(defaults: UserDefaults.standard)
                }
            }
        }
    }
}

/// Tema kartı: takımın zemini üstünde küçük bir kart ve iki yazı çizgisi, altında adı; seçili olan vurgu rengiyle
/// çerçeveli. Sistem teması açık ve koyuyu çapraz bölünmüş gösterir.
private struct ThemeSwatch: View {
    let theme: AppTheme
    let isSelected: Bool
    let accent: Color
    let onSelect: @MainActor () -> Void

    var body: some View {
        let sets: (light: ThemeColorSet, dark: ThemeColorSet) = theme.colorSets
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack {
                    preview(set: sets.light)
                    if theme == .system {
                        preview(set: sets.dark)
                            .clipShape(DiagonalHalf())
                    }
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? accent : Theme.line, lineWidth: isSelected ? 2 : 1))
                Text(themeName(theme: theme))
                    .appFont(size: 12, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func preview(set: ThemeColorSet) -> some View {
        ZStack(alignment: .topLeading) {
            Color(hex: set.background)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: set.ink)).frame(width: 34, height: 5)
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: set.muted)).frame(width: 22, height: 4)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(hex: set.card))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color(hex: set.line)))
                    .frame(height: 22)
            }
            .padding(10)
        }
    }
}

/// Sol üstten sağ alta çapraz bölünmüş sağ-alt yarı.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path: Path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Temanın adı.
private func themeName(theme: AppTheme) -> String {
    switch theme {
    case .system: String(localized: "Sistem")
    case .light: String(localized: "Açık")
    case .dark: String(localized: "Koyu")
    case .paper: String(localized: "Kâğıt")
    case .sand: String(localized: "Kum")
    case .midnight: String(localized: "Gece")
    case .graphite: String(localized: "Grafit")
    }
}

/// Vurgu renginin adı.
private func accentName(accent: PanelAccent) -> String {
    switch accent {
    case .blue: String(localized: "Mavi")
    case .green: String(localized: "Yeşil")
    case .purple: String(localized: "Mor")
    case .orange: String(localized: "Turuncu")
    case .pink: String(localized: "Pembe")
    }
}

/// Cihaz içi modelin (Apple Intelligence) durumu: kullanılabilirlik, ne yapılacağı ve desteklenen diller.
private struct OnDeviceLLMStatus: View {
    @AppStorage(SettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue

    var body: some View {
        let problem: String? = onDeviceProblem()
        let codes: Set<String> = onDeviceLanguageCodes()
        let supported: [String] = MeetingLanguage.allCases
            .filter { onDeviceSupports(language: $0, languageCodes: codes) }
            .map { meetingLanguageName(language: $0) }
        SettingsRow(title: Text("Apple Intelligence")) {
            if let problem {
                Text(verbatim: problem)
            } else {
                Text("Not, çeviri ve soru bu cihazda yazılır: ücretsiz, anahtarsız, internetsiz. Model küçüktür (4 bin token bağlam): uzun toplantılar parça parça işlenir, not kendi anahtarınla seçilen modellerden daha kısa olur.")
            }
        } control: {
            Label(problem == nil ? "Hazır" : "Kullanılamıyor", systemImage: problem == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(problem == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
        }
        SettingsRow(title: Text("Desteklenen diller")) {
            if let warning = MeetingLanguage(rawValue: primaryLanguage).flatMap({ onDeviceLanguageWarning(language: $0, languageCodes: codes) }) {
                Text(verbatim: warning)
            } else {
                Text(verbatim: supported.joined(separator: ", "))
            }
        } control: {
            EmptyView()
        }
    }

    /// Model kullanılamıyorsa nedeni ve ne yapılacağı; kullanılabiliyorsa nil.
    private func onDeviceProblem() -> String? {
        do {
            _ = try onDeviceConfig()
            return nil
        } catch {
            return userFacingMessage(error: error)
        }
    }
}

/// LLM sağlayıcısı: cihaz içi, Anthropic ya da OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…).
private struct LLMSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.llmProvider) private var provider: String = LLMProviderKind.anthropic.rawValue
    @AppStorage(SettingsKey.llmBaseURL) private var baseURL: String = ""
    @AppStorage(SettingsKey.llmFastModel) private var fastModel: String = ""
    @AppStorage(SettingsKey.llmSmartModel) private var smartModel: String = ""
    @AppStorage(SettingsKey.llmFastEffort) private var openAIFastEffort: String = ""
    @AppStorage(SettingsKey.llmSmartEffort) private var openAISmartEffort: String = ""
    @AppStorage(SettingsKey.claudeFastModel) private var claudeFastModel: String = ClaudeModel.haiku.rawValue
    @AppStorage(SettingsKey.claudeSmartModel) private var claudeSmartModel: String = ClaudeModel.opus.rawValue
    @AppStorage(SettingsKey.claudeFastEffort) private var claudeFastEffort: String = LLMEffort.low.rawValue
    @AppStorage(SettingsKey.claudeSmartEffort) private var claudeSmartEffort: String = LLMEffort.medium.rawValue
    @State private var testResult: ConnectionTest = .idle
    /// Süren bağlantı denemesi: ayar değişince iptal edilir (eski ayarın sonucu yeni ayarın yanında görünmesin).
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocalLLMSetup(model: model)
            SettingsRow(title: Text("Sağlayıcı")) {
                EmptyView()
            } control: {
                SettingsMenu(selection: $provider, options: [
                    (LLMProviderKind.onDevice.rawValue, Text("Cihaz içi (ücretsiz, anahtarsız)")),
                    (LLMProviderKind.anthropic.rawValue, Text("Anthropic (Claude)")),
                    (LLMProviderKind.openAICompatible.rawValue, Text("OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…)")),
                ])
            }
            if provider == LLMProviderKind.onDevice.rawValue {
                OnDeviceLLMStatus()
            } else if provider == LLMProviderKind.anthropic.rawValue {
                SecretField(title: "Anthropic anahtarı", account: .anthropic, onChange: model.settingsChanged)
                SettingsGroupHeader(title: "Canlı çeviri")
                SettingsRow(title: Text("Model")) {
                    Text("Hızlı model ve düşük effort önerilir: çeviri 1–2 sn'de gelir. Haiku ve Sonnet'te high ve altında düşünme kapatılır; Opus, Fable ve xhigh/max'ta düşünme açık kalır, çeviriler gecikip birikebilir.")
                } control: {
                    SettingsMenu(selection: $claudeFastModel, options: claudeModelOptions())
                }
                SettingsRow(title: Text("Effort")) {
                    EmptyView()
                } control: {
                    SettingsMenu(selection: $claudeFastEffort, options: claudeEffortOptions(levels: LLMEffort.allCases))
                }
                SettingsGroupHeader(title: "\"Ne kaçırdım?\", soru ve toplantı notu")
                SettingsRow(title: Text("Model")) {
                    Text("Haiku ve yüksek effort önerilir: uzun toplantının notu parça parça yazılır, büyük model gerekmez.")
                } control: {
                    SettingsMenu(selection: $claudeSmartModel, options: claudeModelOptions())
                }
                SettingsRow(title: Text("Effort")) {
                    EmptyView()
                } control: {
                    SettingsMenu(selection: $claudeSmartEffort, options: claudeEffortOptions(levels: smartEfforts))
                }
            } else {
                SettingsRow(title: Text("Temel adres")) {
                    EmptyView()
                } control: {
                    TextField("Temel adres", text: $baseURL, prompt: Text(verbatim: "http://localhost:11434/v1"))
                        .settingsField(width: 260)
                }
                SecretField(title: "Anahtar (Ollama'da gerekmez)", account: .openai, onChange: model.settingsChanged)
                SettingsGroupHeader(title: "Canlı çeviri")
                SettingsRow(title: Text("Model")) {
                    EmptyView()
                } control: {
                    TextField("Model", text: $fastModel, prompt: Text("ör. gpt-5-mini, qwen3:8b")).settingsField(width: 260)
                }
                SettingsRow(title: Text("Effort")) {
                    EmptyView()
                } control: {
                    SettingsMenu(selection: $openAIFastEffort, options: openAIEffortOptions())
                }
                SettingsGroupHeader(title: "\"Ne kaçırdım?\", soru ve toplantı notu")
                SettingsRow(title: Text("Model")) {
                    EmptyView()
                } control: {
                    TextField("Model", text: $smartModel, prompt: Text("ör. gpt-5, gpt-oss:120b")).settingsField(width: 260)
                }
                SettingsRow(title: Text("Effort")) {
                    Text("Effort `reasoning_effort` olarak gönderilir; desteklemeyen sunucularda \"Gönderme\"yi seç.")
                } control: {
                    SettingsMenu(selection: $openAISmartEffort, options: openAIEffortOptions())
                }
            }
            SettingsRow(title: Text("Bağlantıyı dene")) {
                switch testResult {
                case .idle:
                    EmptyView()
                case .running:
                    ProgressView().controlSize(.small)
                case .succeeded(let reply):
                    Label("Çalışıyor: \(reply)", systemImage: "checkmark.circle.fill").foregroundStyle(.tint).lineLimit(1)
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                }
            } control: {
                Button("Bağlantıyı dene") {
                    testResult = .running
                    testTask?.cancel()
                    testTask = Task {
                        let result: ConnectionTest = await testConnection()
                        if !Task.isCancelled {
                            testResult = result
                        }
                    }
                }
                .disabled(testResult == .running)
            }
        }
        // Yazarken her tuşta Keychain denetlenmesin: son değişiklikten 0,6 sn sonra bir kez.
        .task(id: [provider, baseURL, fastModel, smartModel, openAIFastEffort, openAISmartEffort, claudeFastModel, claudeSmartModel, claudeFastEffort, claudeSmartEffort]) {
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                // Yeni bir değişiklik geldi; bu bekleme iptal edildi.
                return
            }
            testTask?.cancel()
            testResult = .idle
            model.settingsChanged()
        }
    }
}

/// Claude modelleri (ad, kısa nitelik). Saf fonksiyondur.
private func claudeModelOptions() -> [(String, Text)] {
    [
        (ClaudeModel.haiku.rawValue, Text("Claude Haiku 5.5 — en hızlı, en ucuz")),
        (ClaudeModel.sonnet.rawValue, Text("Claude Sonnet 5.5 — dengeli")),
        (ClaudeModel.opus.rawValue, Text("Claude Opus 5.5 — güçlü")),
        (ClaudeModel.fable.rawValue, Text("Claude Fable 5.1 — en yetenekli, en pahalı")),
    ]
}

/// Claude effort seviyeleri, düşükten en yükseğe (not/özet için en çok `high`, bkz. `smartEfforts`). Saf fonksiyondur.
private func claudeEffortOptions(levels: [LLMEffort]) -> [(String, Text)] {
    levels.map { (level: LLMEffort) -> (String, Text) in (level.rawValue, Text(effortTitle(level: level))) }
}

/// Effort seviyesinin arayüz adı.
private func effortTitle(level: LLMEffort) -> LocalizedStringKey {
    switch level {
    case .low: "Düşük"
    case .medium: "Orta"
    case .high: "Yüksek"
    case .xhigh: "Çok yüksek"
    case .max: "En yüksek"
    }
}

/// OpenAI uyumlu effort (`reasoning_effort`): gönderme ya da low/medium/high (sunucuların kabul ettiği değerler).
/// Saf fonksiyondur.
private func openAIEffortOptions() -> [(String, Text)] {
    [
        ("", Text("Gönderme")),
        (LLMEffort.low.rawValue, Text("Düşük")),
        (LLMEffort.medium.rawValue, Text("Orta")),
        (LLMEffort.high.rawValue, Text("Yüksek")),
    ]
}

private enum ConnectionTest: Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)
}

/// Seçili sağlayıcının iki modelini de dener: çeviri (hızlı) ve not (akıllı). Biri başarısızsa hangisi olduğu yazılır.
@MainActor
private func testConnection() async -> ConnectionTest {
    let provider: LLMProvider
    do {
        provider = try await resolveLLMProvider()
    } catch {
        return .failed(userFacingMessage(error: error))
    }
    let reply: String
    do {
        reply = try await sendLLM(provider: provider, request: translationRequest(sentence: "Hyvää huomenta.", context: []))
    } catch {
        return .failed(String(localized: "Çeviri modeli: \(userFacingMessage(error: error))"))
    }
    do {
        _ = try await sendLLM(provider: provider, request: LLMRequest(
            tier: .smart, system: "Yalnızca \"tamam\" yaz.", userText: "Bağlantı denemesi", maxTokens: 4000, jsonSchema: nil, timeoutSec: 120
        ))
    } catch {
        return .failed(String(localized: "Not modeli: \(userFacingMessage(error: error))"))
    }
    return .succeeded(reply)
}

/// Bulut konuşma tanıma anahtarları.
private struct KeySettings: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SecretField(title: "Deepgram", account: .deepgram, onChange: model.settingsChanged)
            SecretField(title: "ElevenLabs", account: .elevenlabs, onChange: model.settingsChanged)
            SettingsRow(title: Text("iPhone'da da kullan")) {
                Text("Deepgram, ElevenLabs ve LLM anahtarlarının bir kopyası iCloud Anahtar Zinciri ile iPhone'daki AI-Notepad'e gider; telefonda yeniden girmen gerekmez. Bu Mac'teki anahtarlar değişmez.")
                switch model.keySync {
                case .working:
                    Text("Kopyalanıyor…").foregroundStyle(Theme.ink)
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                case .idle:
                    if !model.sharedKeyAccounts.isEmpty {
                        Text("iPhone'da kullanılıyor: \(model.sharedKeyAccounts.map(secretAccountTitle).joined(separator: ", "))").foregroundStyle(Theme.ink)
                    }
                }
            } control: {
                HStack(spacing: 8) {
                    if !model.sharedKeyAccounts.isEmpty {
                        Button("Kaldır", role: .destructive) { Task { await model.stopSharingKeys() } }
                            .hoverHint("Kopyalar iCloud'dan silinir; iPhone'da anahtarlar yeniden girilmeli", alignment: .trailing, edge: .bottom)
                    }
                    Button(model.sharedKeyAccounts.isEmpty ? "iPhone'a gönder" : "Güncelle") { Task { await model.shareKeysWithIPhone() } }
                }
                .disabled(model.keySync == .working)
            }
            Text("Anahtarlar macOS Anahtar Zinciri'nde saklanır ve hiçbir zaman gösterilmez. Terminal'den eklediysen ilk kullanımda çıkan izin penceresinde \"Her Zaman İzin Ver\"i seç.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
    }
}

/// Bağlantılar: yapay zekâ uygulamalarına tek tıkla MCP (Claude, Cursor, VS Code), kanallara not gönderme (webhook) ve
/// başka MCP istemcileri için elle yapılandırma.
private struct ConnectionSettings: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "Yapay zekâ uygulamaları")
            Text("Bağlayınca Claude, Cursor ya da VS Code toplantılarını listeleyip arar, notları ve transkriptleri okur (yalnızca okur, hiçbir şey değiştirmez). Okuduğunu kendi yapay zekâ sağlayıcısına gönderir.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            ForEach(MCPClient.allCases, id: \.self) { (client: MCPClient) in
                MCPClientRow(client: client)
            }
            WebhookSettings(model: model)
            TaskTrackerSettings(model: model)
            SkillSettings(model: model)
            MCPSettings()
        }
    }
}

/// Bir yapay zekâ uygulaması: simgesi, adı, durumu; yüklüyse "Bağla" ya da (bağlıysa) "Kaldır". Bağlayınca uygulamanın
/// yapılandırma dosyasına AI-Notepad eklenir (diğer ayarlar korunur); uygulama yeniden açılınca görünür.
private struct MCPClientRow: View {
    let client: MCPClient
    @State private var isConnected: Bool = false
    @State private var errorMessage: String?
    @State private var justConnected: Bool = false

    private var isInstalled: Bool {
        FileManager.default.fileExists(atPath: client.applicationPath)
    }

    /// Yapılandırmaya yazılacak uygulama yolu; uygulama geçici konumdan çalışıyorsa hata.
    private func executablePath() throws -> String {
        guard let path = Bundle.main.executablePath else {
            throw MCPConfigError.writeFailed(path: Bundle.main.bundlePath, reason: "uygulamanın çalıştırılabilir dosyası bulunamadı")
        }
        return try mcpExecutablePath(executablePath: path)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Group {
                    if isInstalled {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: client.applicationPath))
                            .resizable()
                    } else {
                        // Yüklü olmayan uygulamada sistem genel belge simgesi verir: yerine sade, soluk simge.
                        Image(systemName: "app.dashed")
                            .appFont(size: 18, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .frame(width: 34, height: 34)
                            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: client.displayName)
                        .appFont(size: 15, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    Group {
                        if !isInstalled {
                            Text("Bu Mac'te yüklü değil").foregroundStyle(Theme.muted)
                        } else if let errorMessage {
                            Text(errorMessage).foregroundStyle(.red)
                        } else if isConnected {
                            Label(justConnected ? "Bağlandı — uygulamayı yeniden aç" : "Bağlı", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        } else {
                            Text("Tek tıkla bağla").foregroundStyle(Theme.muted)
                        }
                    }
                    .appFont(size: 13, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if isInstalled {
                    if isConnected {
                        Button("Kaldır", role: .destructive) { disconnect() }
                    } else {
                        Button("Bağla", systemImage: "link") { connect() }
                            .buttonStyle(.pillPrimary)
                    }
                }
            }
            .padding(.vertical, 14)
            SettingsDivider()
        }
        .animation(.smooth(duration: 0.2), value: isConnected)
        .task { refresh() }
    }

    private func refresh() {
        guard isInstalled else {
            return
        }
        do {
            let config: JSONValue = try readMCPConfig(file: client.configFile(home: FileManager.default.homeDirectoryForCurrentUser))
            isConnected = isMCPServerConnected(config: config, client: client, executablePath: try executablePath())
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func connect() {
        do {
            try connectMCPClient(client: client, executablePath: try executablePath(), home: FileManager.default.homeDirectoryForCurrentUser)
            justConnected = true
            refresh()
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func disconnect() {
        do {
            try disconnectMCPClient(client: client, home: FileManager.default.homeDirectoryForCurrentUser)
            justConnected = false
            refresh()
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

/// Eklenebilen hedef kartı: hesapla tek tıkla bağlanan servisler, Notion ve adresle bağlanan her şey.
private enum ChannelCard: String, CaseIterable, Identifiable {
    case slack
    case teams
    case discord
    case notion
    case zoom
    case webhook

    var id: String { rawValue }

    var name: String {
        switch self {
        case .slack: "Slack"
        case .teams: "Microsoft Teams"
        case .discord: "Discord"
        case .notion: "Notion"
        case .zoom: "Zoom Team Chat"
        case .webhook: String(localized: "Webhook adresi")
        }
    }

    var symbol: String {
        switch self {
        case .slack: "number"
        case .teams: "person.3.fill"
        case .discord: "bubble.left.and.bubble.right.fill"
        case .notion: "doc.richtext.fill"
        case .zoom: "video.fill"
        case .webhook: "bolt.horizontal.fill"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .slack: "Kendi adınla, seçtiğin kanala"
        case .teams: "İş ya da okul hesabı (kişisel hesaplar desteklenmiyor)"
        case .discord: "Sunucu ve kanalı Discord'da seç"
        case .notion: "Her toplantı için yeni sayfa"
        case .zoom: "Kanalda /inc connect yaz, adresi ve anahtarı yapıştır"
        case .webhook: "Zapier, Make, n8n, Teams iş akışı"
        }
    }

    /// Hesapla girişin servisi (Slack, Teams, Discord); diğerlerinde nil.
    var service: ChannelService? {
        switch self {
        case .slack: .slack
        case .teams: .teams
        case .discord: .discord
        case .notion, .zoom, .webhook: nil
        }
    }

    /// Bu karttan eklenmiş hedef mi. Saf fonksiyondur.
    func matches(destination: NoteDestination) -> Bool {
        switch destination.target {
        case .account(let connection): service == connection.service
        case .notion: self == .notion
        case .webhook(let url):
            switch webhookKind(url: url) {
            case .slack: self == .slack
            case .discord: self == .discord
            case .teams: self == .teams
            case .zoom: self == .zoom
            case .generic: self == .webhook
            }
        }
    }
}

/// Kanal kurulumunun durumu.
private enum ChannelSetup: Equatable {
    case idle
    /// Tarayıcıda giriş bekleniyor.
    case signingIn(String)
    /// Giriş tamam; yazılacak kanal seçiliyor (`replacing`: kanalı değiştirilen hedef).
    case choosing(ChannelSignIn, [ChannelOption], replacing: String?)
    /// Webhook adresi yapıştırılıyor.
    case pasting
    /// Zoom adresi ve doğrulama anahtarı yapıştırılıyor.
    case pastingZoom
    case working(String)
    case done(String)
    case failed(String)
}

/// Kanallara gönder: bağlı hedefler (her birinin kendiliğinden gönderimi, dene, kanalı değiştir, yeniden bağlan,
/// kaldır), yeni hedef ekleme kartları (Slack, Teams, Discord, Notion, Zoom, webhook), Apple Notlar ve klasör. Birden
/// çok hedef aynı anda bağlı olabilir.
private struct WebhookSettings: View {
    let model: AppModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage(SettingsKey.appleNotesAutoSend) private var notesAutoSend: Bool = false
    @AppStorage(SettingsKey.markdownFolder) private var markdownFolder: String = ""
    @AppStorage(SettingsKey.markdownAutoExport) private var markdownAuto: Bool = false
    @State private var setup: ChannelSetup = .idle
    @State private var selectedChannelID: String = ""
    @State private var manualAddress: String = ""
    @State private var zoomToken: String = ""
    @State private var notesStatus: String?
    @State private var folderStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "Kanallara gönder")
            Text("Her toplantının notu (önce görevler, sonra kararlar ve özet) bağladığın yerlere gider; her hedefte kendiliğinden gönderimi ayrı açabilirsin. Toplantı sayfasındaki ⋯ menüsünden elle de gönderilir. Ağ yokken kaçan gönderimler sonra kendiliğinden gider.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            ForEach(model.destinations) { (destination: NoteDestination) in
                destinationRow(destination: destination)
            }
            setupStatus
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ChannelCard.allCases) { (card: ChannelCard) in
                    channelCard(card: card)
                }
                appleNotesCard
                folderCard
            }
            .padding(.vertical, 6)
        }
        .task { await model.loadDestinations() }
    }

    /// Bağlı hedef: ad, kanal, kendiliğinden gönderim, dene, kanalı değiştir ya da yeniden bağlan, kaldır.
    private func destinationRow(destination: NoteDestination) -> some View {
        SettingsRow(title: Text(verbatim: destinationName(destination: destination))) {
            if destination.needsReconnect {
                Label("Oturumun süresi doldu; yeniden bağlan", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label(String(localized: "Bağlı · \(destinationDetail(destination: destination))"), systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        } control: {
            HStack(spacing: 8) {
                if case .account(let connection) = destination.target {
                    if destination.needsReconnect {
                        Button("Yeniden bağlan") { Task { await signIn(service: connection.service, replacing: destination.id) } }
                            .buttonStyle(.pillPrimary)
                    } else {
                        Button("Kanalı değiştir") { Task { await changeChannel(destinationID: destination.id, service: connection.service) } }
                            .disabled(isBusy)
                    }
                }
                if case .notion = destination.target, destination.needsReconnect {
                    Button("Yeniden bağlan") { Task { await reconnectNotion(destinationID: destination.id) } }
                        .buttonStyle(.pillPrimary)
                }
                Button("Dene") { Task { await test(destinationID: destination.id) } }
                    .disabled(isBusy)
                Button("Kaldır", role: .destructive) { Task { await model.removeDestination(id: destination.id) } }
                Toggle("Kendiliğinden gönder", isOn: Binding<Bool>(
                    get: { destination.autoSend },
                    set: { (enabled: Bool) -> Void in Task { await model.setAutoSend(destinationID: destination.id, enabled: enabled) } }
                ))
                .settingsToggle()
                .hoverHint("Not hazır olunca kendiliğinden gönder", alignment: .trailing, edge: .bottom)
            }
        }
    }

    @ViewBuilder
    private var setupStatus: some View {
        switch setup {
        case .idle:
            EmptyView()
        case .signingIn(let name):
            statusPanel {
                ProgressView().controlSize(.small)
                Text("Açılan pencerede \(name) hesabınla giriş yap ve izin ver.").appFont(size: 13, weight: .regular)
                Spacer()
            }
        case .choosing(let signIn, let options, let replacing):
            statusPanel {
                Text("Notlar hangi kanala gitsin?").appFont(size: 13, weight: .medium)
                Picker("Kanal", selection: $selectedChannelID) {
                    Text("Kanal seç").tag("")
                    ForEach(options) { (option: ChannelOption) in
                        Text(verbatim: option.name).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                Button("Vazgeç") { setup = .idle }.buttonStyle(.hoverPlain).foregroundStyle(Theme.muted)
                Button("Bağla") { choose(signIn: signIn, options: options, replacing: replacing) }
                    .buttonStyle(.pillPrimary)
                    .disabled(!options.contains { $0.id == selectedChannelID })
            }
        case .pasting:
            statusPanel {
                TextField("Webhook adresi", text: $manualAddress, prompt: Text(verbatim: "https://hooks.zapier.com/…"))
                    .textFieldStyle(.roundedBorder)
                Button("Vazgeç") { setup = .idle }.buttonStyle(.hoverPlain).foregroundStyle(Theme.muted)
                Button("Bağla") { connectWebhook() }
                    .buttonStyle(.pillPrimary)
                    .disabled(manualAddress.isEmpty)
            }
        case .pastingZoom:
            statusPanel {
                TextField("Zoom adresi", text: $manualAddress, prompt: Text(verbatim: "https://integrations.zoom.us/chat/webhooks/incomingwebhook/…"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Doğrulama anahtarı", text: $zoomToken, prompt: Text("Doğrulama anahtarı"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Button("Vazgeç") { setup = .idle }.buttonStyle(.hoverPlain).foregroundStyle(Theme.muted)
                Button("Bağla") { connectZoom() }
                    .buttonStyle(.pillPrimary)
                    .disabled(manualAddress.isEmpty || zoomToken.isEmpty)
            }
        case .working(let message):
            Label(message, systemImage: "paperplane").appFont(size: 13, weight: .regular).padding(.bottom, 8)
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .appFont(size: 13, weight: .medium).foregroundStyle(.tint).padding(.bottom, 8)
        case .failed(let message):
            Text(message)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
        }
    }

    private func statusPanel(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(12)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 8)
    }

    private func channelCard(card: ChannelCard) -> some View {
        let count: Int = model.destinations.filter { card.matches(destination: $0) }.count
        return destinationCard(symbol: card.symbol, title: Text(verbatim: card.name), detail: card.detail) {
            HStack(spacing: 6) {
                if count > 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Bağlı"))
                }
                Button(count > 0 ? "Ekle" : (card.service == nil && card != .notion ? "Yapıştır" : "Bağlan")) { start(card: card) }
                    .buttonStyle(.pillPrimary)
                    .controlSize(.small)
                    .disabled(isBusy)
            }
        }
    }

    /// Giriş, gönderim ya da deneme sürüyor: ikinci bir kurulum başlamasın.
    private var isBusy: Bool {
        switch setup {
        case .signingIn, .working: true
        case .idle, .choosing, .pasting, .pastingZoom, .done, .failed: false
        }
    }

    private var appleNotesCard: some View {
        destinationCard(symbol: "note.text", title: Text("Apple Notlar"), detail: notesStatus.map { LocalizedStringKey($0) } ?? "\"AI-Notepad\" klasörüne, hesap gerekmez") {
            Toggle("Apple Notlar'a gönder", isOn: $notesAutoSend)
                .settingsToggle()
                .onChange(of: notesAutoSend) { (_: Bool, enabled: Bool) in
                    // İlk açılışta izin penceresi çıksın ve doğru çalıştığı görülsün: son not gönderilir.
                    if enabled, let latest = model.meetings.first(where: { $0.note != nil }) {
                        Task {
                            let error: String? = await model.sendToAppleNotes(meetingID: latest.id)
                            notesStatus = error ?? String(localized: "Son not Notlar'a yazıldı.")
                            if error != nil {
                                notesAutoSend = false
                            }
                        }
                    }
                }
        }
    }

    private var folderCard: some View {
        destinationCard(
            symbol: "folder.fill", title: Text("Klasör (Obsidian, iCloud)"),
            detail: folderStatus.map { LocalizedStringKey($0) } ?? (markdownFolder.isEmpty ? "Markdown dosyası olarak" : LocalizedStringKey((markdownFolder as NSString).abbreviatingWithTildeInPath))
        ) {
            if markdownFolder.isEmpty {
                Button("Seç…") { chooseFolder() }
                    .buttonStyle(.pillPrimary)
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Button("Değiştir") { chooseFolder() }.controlSize(.small)
                    Toggle("Klasöre yaz", isOn: $markdownAuto).settingsToggle()
                }
            }
        }
    }

    private func destinationCard(symbol: String, title: Text, detail: LocalizedStringKey, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .appFont(size: 14, weight: .medium)
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            VStack(alignment: .leading, spacing: 2) {
                title.appFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink).lineLimit(1)
                Text(detail).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer(minLength: 6)
            action()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
    }

    private func start(card: ChannelCard) {
        manualAddress = ""
        zoomToken = ""
        switch card {
        case .zoom:
            setup = .pastingZoom
        case .webhook:
            setup = .pasting
        case .notion:
            Task { await connectNotion() }
        case .slack, .teams, .discord:
            if let service = card.service {
                Task { await signIn(service: service, replacing: nil) }
            }
        }
    }

    /// Tarayıcıda giriş (PKCE); Discord'da kanal orada seçilir ve eklenir, Slack ve Teams'te kanal listesi gelir.
    /// `replacing` verilirse (yeniden bağlan) yeni bağlantı o hedefin yerine geçer. Pencere kapatılırsa vazgeçilir.
    private func signIn(service: ChannelService, replacing: String?) async {
        let clientID: String = channelClientID(service: service)
        guard !clientID.isEmpty else {
            setup = .failed(userFacingMessage(error: ChannelAuthError.notConfigured(service: service)))
            return
        }
        let pkce: PKCEPair = makePKCEPair()
        let state: String = makeOAuthState()
        setup = .signingIn(service.displayName)
        do {
            let callback: URL = try await webAuthenticationSession.authenticate(
                using: channelAuthorizeURL(service: service, clientID: clientID, pkce: pkce, state: state),
                callback: .customScheme(oauthCallbackScheme), preferredBrowserSession: nil, additionalHeaderFields: [:]
            )
            let code: String = try oauthCallbackCode(service: service, url: callback, expectedState: state)
            switch service {
            case .discord:
                let url: URL = try await exchangeDiscordCode(code: code, verifier: pkce.verifier, clientID: clientID)
                let destination: NoteDestination = try await model.addDestination(target: .webhook(url))
                await test(destinationID: destination.id)
            case .slack:
                await showChannels(signIn: try await exchangeSlackCode(code: code, verifier: pkce.verifier, clientID: clientID), replacing: replacing)
            case .teams:
                await showChannels(signIn: try await exchangeTeamsCode(code: code, verifier: pkce.verifier, clientID: clientID), replacing: replacing)
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            setup = .idle
        } catch {
            channelSettingsLogger.error("Kanal girişi başarısız, servis: \(service.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func showChannels(signIn: ChannelSignIn, replacing: String?) async {
        do {
            let options: [ChannelOption] = try await listChannels(signIn: signIn)
            // Kanal önceden seçilmez: notlar yanlışlıkla herkesin gördüğü #genel'e gitmesin.
            selectedChannelID = ""
            setup = .choosing(signIn, options, replacing: replacing)
        } catch {
            setup = .failed(userFacingMessage(error: error))
        }
    }

    /// Seçilen kanalla bağlantıyı yeni hedef olarak ekler (ya da değiştirilen hedefin yerine koyar) ve dener.
    private func choose(signIn: ChannelSignIn, options: [ChannelOption], replacing: String?) {
        guard let option = options.first(where: { $0.id == selectedChannelID }) else {
            return
        }
        let connection: ChannelConnection = ChannelConnection(service: signIn.service, tokens: signIn.tokens, workspace: signIn.workspace, channel: option)
        Task {
            do {
                if let replacing {
                    try await model.replaceDestinationTarget(id: replacing, target: .account(connection))
                    await test(destinationID: replacing)
                } else {
                    let destination: NoteDestination = try await model.addDestination(target: .account(connection))
                    await test(destinationID: destination.id)
                }
            } catch {
                setup = .failed(userFacingMessage(error: error))
            }
        }
    }

    /// Kayıtlı oturumla kanalları yeniden listeler (yeniden giriş gerekmez).
    private func changeChannel(destinationID: String, service: ChannelService) async {
        setup = .signingIn(service.displayName)
        do {
            let result: (signIn: ChannelSignIn, options: [ChannelOption]) = try await model.channelOptions(destinationID: destinationID)
            selectedChannelID = ""
            setup = .choosing(result.signIn, result.options, replacing: destinationID)
        } catch {
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func connectNotion() async {
        setup = .signingIn("Notion")
        do {
            try await model.connectNotion()
            setup = .done(String(localized: "Notion bağlandı; notlar özel sayfalarına yeni sayfa olarak gider."))
        } catch is CancellationError {
            setup = .idle
        } catch {
            channelSettingsLogger.error("Notion girişi başarısız, hata: \(String(describing: error), privacy: .private)")
            setup = .failed(userFacingMessage(error: error))
        }
    }

    /// Notion oturumu bitti: yeni bağlantı kurulur, eski hedef kaldırılır (ayarı korunur).
    private func reconnectNotion(destinationID: String) async {
        let autoSend: Bool = model.destinations.first { $0.id == destinationID }?.autoSend ?? false
        await connectNotion()
        guard case .done = setup else {
            return
        }
        await model.removeDestination(id: destinationID)
        if autoSend, let added = model.destinations.last(where: { if case .notion = $0.target { true } else { false } }) {
            await model.setAutoSend(destinationID: added.id, enabled: true)
        }
    }

    private func connectWebhook() {
        do {
            addWebhook(url: try webhookURL(text: manualAddress))
        } catch {
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func connectZoom() {
        do {
            addWebhook(url: try zoomWebhookURL(address: manualAddress, token: zoomToken))
            zoomToken = ""
        } catch {
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func addWebhook(url: URL) {
        Task {
            do {
                let destination: NoteDestination = try await model.addDestination(target: .webhook(url))
                await test(destinationID: destination.id)
            } catch {
                setup = .failed(userFacingMessage(error: error))
            }
        }
    }

    private func test(destinationID: String) async {
        let name: String = model.destinations.first { $0.id == destinationID }.map { destinationName(destination: $0) } ?? ""
        setup = .working(String(localized: "Deneme mesajı gönderiliyor…"))
        if let error = await model.sendTestNote(destinationID: destinationID) {
            setup = .failed(error)
        } else {
            setup = .done(String(localized: "\(name) bağlandı; deneme mesajı gönderildi."))
        }
    }

    private func chooseFolder() {
        let panel: NSOpenPanel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Seç")
        panel.message = String(localized: "Notların Markdown olarak yazılacağı klasör (ör. Obsidian kasası)")
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        markdownFolder = url.path
        markdownAuto = true
        folderStatus = model.meetings.first(where: { $0.note != nil }).flatMap { model.exportToFolder(meetingID: $0.id) }
            ?? String(localized: "Son not klasöre yazıldı.")
    }
}

/// Görev araçları: Linear ve Jira'ya tek tıkla bağlanma (MCP, tarayıcıda izin; API anahtarı gerekmez), görevlerin
/// açılacağı takım ya da proje, kaldırma.
private struct TaskTrackerSettings: View {
    let model: AppModel
    @State private var status: String?
    @State private var connecting: MCPService?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "Görev araçları")
            Text("Toplantıdaki görevleri tek tıkla Linear ya da Jira'da iş olarak açar (toplantı sayfası › ⋯ › Görevleri gönder). Bağlantı Linear ve Atlassian'ın resmi MCP sunucusuyla, tarayıcıda izin vererek kurulur; işleri yapay zekâ sağlayıcın açar.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            ForEach([MCPService.linear, MCPService.atlassian], id: \.self) { (service: MCPService) in
                trackerRow(service: service)
            }
            if let status {
                Text(status)
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func trackerRow(service: MCPService) -> some View {
        if let tracker = model.taskTrackers.first(where: { $0.service == service }) {
            SettingsRow(title: Text(verbatim: service.displayName)) {
                Label("Bağlı", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
            } control: {
                HStack(spacing: 8) {
                    TextField(
                        service == .atlassian ? "Proje (boş: ilki)" : "Takım (boş: ilki)",
                        text: Binding<String>(get: { tracker.target }, set: { (value: String) -> Void in model.setTrackerTarget(id: tracker.id, target: value) })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    Button("Kaldır", role: .destructive) { model.removeTracker(id: tracker.id) }
                }
            }
        } else {
            SettingsRow(title: Text(verbatim: service.displayName)) {
                Text(service == .linear ? "Takımındaki işler" : "Jira projesindeki işler")
            } control: {
                Button(connecting == service ? "Tarayıcıda izin ver…" : "Bağlan") { connect(service: service) }
                    .buttonStyle(.pillPrimary)
                    .disabled(connecting != nil)
            }
        }
    }

    private func connect(service: MCPService) {
        connecting = service
        status = nil
        Task {
            defer { connecting = nil }
            do {
                try await model.connectTracker(service: service)
                status = String(localized: "\(service.displayName) bağlandı.")
            } catch is CancellationError {
                status = nil
            } catch {
                status = userFacingMessage(error: error)
            }
        }
    }
}

/// Agent Skills: Claude ve diğer araçlar için yazılmış becerileri (`SKILL.md`) Sor'da "/" tarifi olarak kullanma.
private struct SkillSettings: View {
    let model: AppModel
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "Beceriler (Agent Skills)")
            SettingsRow(title: Text("SKILL.md içe aktar")) {
                Text("Claude ve diğer yapay zekâ araçları için yazılmış beceriler Sor'da \"/\" ile tarif olarak çalışır (ör. haftalık özet, takip e-postası).")
            } control: {
                Button("İçe aktar…") { importSkills() }
            }
            if let status {
                Text(status)
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private func importSkills() {
        let panel: NSOpenPanel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.prompt = String(localized: "İçe aktar")
        panel.message = String(localized: "Agent Skill dosyalarını (SKILL.md) seç")
        guard panel.runModal() == .OK else {
            return
        }
        let failures: [String] = model.importSkills(files: panel.urls)
        let added: Int = panel.urls.count - failures.count
        status = ([added > 0 ? String(localized: "\(added) beceri Sor'a tarif olarak eklendi.") : nil] + failures).compactMap { $0 }.joined(separator: "\n")
    }
}

private let channelSettingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Settings")

/// Kısayolları değiştirme.
private struct ShortcutSettings: View {
    let shortcuts: ShortcutController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ShortcutAction.allCases, id: \.self) { (action: ShortcutAction) in
                SettingsRow(title: Text(action.title)) {
                    if let error = shortcuts.errors[action] {
                        Text(error).foregroundStyle(.red)
                    }
                } control: {
                    ShortcutRecorder(binding: shortcuts.currentBinding(action: action)) { (binding: KeyBinding) -> Void in
                        shortcuts.change(action: action, binding: binding)
                    }
                }
            }
            Text("Kısayola tıklayıp yeni tuşlara bas; vazgeçmek için Esc. ⌃, ⌥ ya da ⌘ ile birlikte bir harf ya da rakam seç.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
    }
}

/// Tıklanınca bir sonraki tuş bileşimini kaydeden düğme.
private struct ShortcutRecorder: View {
    let binding: KeyBinding
    let onRecord: @MainActor (KeyBinding) -> Void
    @State private var isRecording: Bool = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? String(localized: "Tuşlara bas…") : keyBindingDisplay(binding: binding))
                .monospaced()
                .frame(minWidth: 110)
        }
        .accessibilityLabel(isRecording ? String(localized: "Kısayol kaydediliyor") : String(localized: "Kısayol: \(keyBindingDisplay(binding: binding)). Değiştir"))
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { (event: NSEvent) -> NSEvent? in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) {
                    stop()
                } else {
                    onRecord(KeyBinding(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers(flags: event.modifierFlags)))
                    stop()
                }
            }
            // Tuş başka bir yere yazılmasın.
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}

/// AppKit değiştiricilerini Carbon maskesine çevirir. Saf fonksiyondur.
func carbonModifiers(flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.control) { modifiers |= CarbonModifier.control }
    if flags.contains(.option) { modifiers |= CarbonModifier.option }
    if flags.contains(.shift) { modifiers |= CarbonModifier.shift }
    if flags.contains(.command) { modifiers |= CarbonModifier.command }
    return modifiers
}

// MARK: Ayar satırı bileşenleri

/// Ayar satırı (ElevenLabs): solda başlık ve soluk açıklama, sağda denetim; altında ince çizgi.
struct SettingsRow<Detail: View, Control: View>: View {
    let title: Text
    let detail: Detail
    let control: Control

    init(title: Text, @ViewBuilder detail: () -> Detail, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail()
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    title
                        .appFont(size: 15, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    VStack(alignment: .leading, spacing: 3) {
                        detail
                    }
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Denetim sığdığı genişlikte kalır; dar pencerede açıklama satırları kısalır (düğme yazıları ezilmesin).
                control.fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 16)
            SettingsDivider()
        }
    }
}

/// Satırlar arasındaki ince çizgi.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }
}

/// Satır grubunun başlığı (ör. LLM'de "Canlı çeviri").
struct SettingsGroupHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .appFont(size: 12, weight: .semibold)
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(Theme.muted)
            .padding(.top, 32)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Açılır seçim: beyaz hap düğme (seçili değer ve ok); menüde seçili değer işaretli.
struct SettingsMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, Text)]

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { (item: (offset: Int, element: (Value, Text))) in
                    item.element.1.tag(item.element.0)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                options.first { $0.0 == selection }?.1 ?? Text(verbatim: "–")
                Image(systemName: "chevron.up.chevron.down")
                    .appFont(size: 10, weight: .semibold)
                    .foregroundStyle(Theme.muted)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.pill)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

extension View {
    /// Ayar yazı alanı: düz alan, beyaz zemin, ince çerçeve.
    func settingsField(width: CGFloat) -> some View {
        textFieldStyle(.plain)
            .appFont(size: 14, weight: .regular)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: width)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
    }

    /// Ayar anahtarı: etiketsiz, vurgu renginde.
    func settingsToggle() -> some View {
        toggleStyle(.switch).labelsHidden()
    }
}

/// İstemcinin MCP yapılandırması; yol JSON olarak kaçışlanır (tırnak ya da ters bölü içeren yol yapılandırmayı bozmasın).
/// Saf fonksiyondur.
func mcpClientConfig(executablePath: String) -> String {
    let encoded: String = "\"" + executablePath.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    return """
    {
      "mcpServers": {
        "ai-notepad": {
          "command": \(encoded),
          "args": ["--mcp"]
        }
      }
    }
    """
}

/// Yerel MCP sunucusu: Claude Desktop, ChatGPT ya da başka MCP istemcisinin toplantı arşivini sorgulaması için
/// yapılandırma (uygulama `--mcp` ile pencere açmadan çalışır; istemci yalnızca okur ve okuduğunu kendi yapay zekâ
/// sağlayıcısına gönderir).
private struct MCPSettings: View {
    @State private var copied: Bool = false

    var body: some View {
        // Elle kopyalanan yapılandırma da uygulamanın gerçek yolunu gösterir (uygulama paketi her zaman bir çalıştırılabilir içerir).
        let config: String = mcpClientConfig(executablePath: Bundle.main.executableURL?.path ?? Bundle.main.bundlePath)
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "Diğer MCP istemcileri")
            SettingsRow(title: Text("Elle yapılandırma")) {
                Text("Bu yapılandırmayı istemcinin MCP ayarlarına (Claude Desktop: Ayarlar › Geliştirici › Yapılandırmayı düzenle) ekle. İstemci toplantılarını listeler, arar, notları ve transkriptleri okur; yalnızca okur, hiçbir şey değiştirmez. Okunan notlar ve transkriptler istemcinin yapay zekâ sağlayıcısına (ör. Anthropic, OpenAI) gönderilir.")
            } control: {
                Button(copied ? "Kopyalandı" : "Yapılandırmayı kopyala", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(config, forType: .string)
                    copied = true
                }
            }
            Text(config)
                .appFont(size: 12, weight: .regular)
                .monospaced()
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.vertical, 12)
        }
    }
}

/// Anahtarsız kullanım: Mac'teki Ollama algılanır, yüklü modellerden önerilen seçilir ve tek tıkla LLM sağlayıcısı
/// yapılır (OpenAI uyumlu, `localhost:11434`). Bulut modelleri işaretlenir (metin Ollama'ya gider). Ollama yoksa kurulum
/// adımları gösterilir.
struct LocalLLMSetup: View {
    let model: AppModel
    @State private var state: DetectState = .idle
    @State private var choice: String = ""

    private enum DetectState: Equatable {
        case idle
        case detecting
        case found([String])
        case missing(String)
        case applied(String)
    }

    var body: some View {
        SettingsRow(title: Text("Mac'te, anahtarsız (Ollama)")) {
            switch state {
            case .idle, .detecting:
                Text("Yerel model (ör. gpt-oss:20b, qwen3) ile not ve çeviri: anahtar gerekmez, toplantı metni Mac'ten çıkmaz. Konuşma tanıma için Genel › Canlı metin'de \"Mac'te (WhisperKit)\" seç.")
            case .found(let names):
                Text("\(names.count) model bulundu. Bulut modelleri (\"cloud\") internet ister ve metni Ollama'ya gönderir.")
            case .missing(let message):
                Text("Ollama bulunamadı (\(message)). ollama.com'dan kur, sonra Terminal'de: ollama pull gpt-oss:20b").foregroundStyle(.orange)
            case .applied(let name):
                Label("Kullanılıyor: \(name). Bağlantıyı denemek için LLM sekmesi.", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        } control: {
            HStack(spacing: 8) {
                if case .found(let names) = state {
                    SettingsMenu(selection: $choice, options: names.map { (name: String) -> (String, Text) in
                        (name, isOllamaCloudModel(name: name) ? Text(verbatim: "\(name) ☁︎") : Text(verbatim: name))
                    })
                    Button("Kullan") { apply(name: choice) }
                        .buttonStyle(.pillPrimary)
                        .disabled(choice.isEmpty)
                } else {
                    Button(state == .detecting ? "Aranıyor…" : "Algıla", systemImage: "magnifyingglass") { detect() }
                        .disabled(state == .detecting)
                }
            }
        }
    }

    private func detect() {
        state = .detecting
        Task {
            do {
                let names: [String] = try await ollamaModels(baseURL: URL(string: "http://localhost:11434/v1")!).filter(isChatModel)
                guard let recommended = recommendedOllamaModel(names: names) else {
                    state = .missing(String(localized: "sohbet modeli yüklü değil"))
                    return
                }
                choice = recommended
                state = .found(names)
            } catch {
                state = .missing(error.localizedDescription)
            }
        }
    }

    /// Sağlayıcıyı Ollama'ya çevirir: iki model sınıfı da seçilen model, effort gönderilmez (her sunucu desteklemez).
    private func apply(name: String) {
        let defaults: UserDefaults = .standard
        defaults.set(LLMProviderKind.openAICompatible.rawValue, forKey: SettingsKey.llmProvider)
        defaults.set("http://localhost:11434/v1", forKey: SettingsKey.llmBaseURL)
        defaults.set(name, forKey: SettingsKey.llmFastModel)
        defaults.set(name, forKey: SettingsKey.llmSmartModel)
        defaults.set("", forKey: SettingsKey.llmFastEffort)
        defaults.set("", forKey: SettingsKey.llmSmartEffort)
        model.settingsChanged()
        state = .applied(name)
    }
}

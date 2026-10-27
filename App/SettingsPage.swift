import AINotepadCore
import AINotepadUI
import AppKit
import Carbon.HIToolbox
import SwiftUI

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
    case "kisayollar": return .shortcuts
    default: return .general
    }
}

private enum SettingsSection: CaseIterable {
    case general
    case appearance
    case llm
    case keys
    case shortcuts

    var title: LocalizedStringKey {
        switch self {
        case .general: "Genel"
        case .appearance: "Görünüm"
        case .llm: "LLM"
        case .keys: "Anahtarlar"
        case .shortcuts: "Kısayollar"
        }
    }
}

/// Ana penceredeki Ayarlar (ElevenLabs düzeni): büyük başlık, altı çizili sekmeler; her ayar ince çizgiyle ayrılmış bir
/// satır (solda başlık ve açıklama, sağda denetim).
struct SettingsPage: View {
    let model: AppModel
    let shortcuts: ShortcutController
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
                    case .general: GeneralSettings(model: model)
                    case .appearance: AppearanceSettings()
                    case .llm: LLMSettings(model: model)
                    case .keys: KeySettings(model: model)
                    case .shortcuts: ShortcutSettings(shortcuts: shortcuts)
                    }
                }
                .id(section)
                .transition(.opacity)
                .padding(.top, 8)
            }
            .animation(.smooth(duration: 0.2), value: section)
            .frame(maxWidth: 880, alignment: .leading)
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
    @AppStorage(SettingsKey.userName) private var userName: String = ""
    @AppStorage(SettingsKey.missedWindowMinutes) private var missedMinutes: Int = 3
    @AppStorage(SettingsKey.audioRetentionDays) private var retentionDays: Int = 30
    @AppStorage(SettingsKey.voiceRecognition) private var voiceRecognition: Bool = true
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
                Text(model.liveEngine == .deepgram
                    ? "Konuşmacılar ElevenLabs ile dakikada bir ayrılır; kayıt bitince ElevenLabs son geçişi yapılır."
                    : "Ses Mac'ten çıkmaz; kayıt bitince konuşmacılar Mac'te (SpeakerKit) ayrılır. Not için LLM gerekir.")
            } control: {
                SettingsMenu(selection: Binding<LiveEngine>(
                    get: { model.liveEngine },
                    set: { (engine: LiveEngine) -> Void in
                        Task { await model.selectEngine(engine: engine) }
                    }
                ), options: [
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
                Text("Ad verdiğin kişilerin ses izi (ses değil, yalnızca sayılar) bu Mac'te saklanır: sonraki toplantılarda adı kendiliğinden gelir, kayıtta bir süre susup dönen kişi aynı numarayı alır. Emin olunmayan durumda ad verilmez.")
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
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: Text("Tema")) {
                EmptyView()
            } control: {
                PillPicker(selection: $theme, options: [
                    (AppTheme.system.rawValue, "Sistem"), (AppTheme.light.rawValue, "Açık"), (AppTheme.dark.rawValue, "Koyu"),
                ])
                .fixedSize()
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

/// LLM sağlayıcısı: Anthropic ya da OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…).
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
                    (LLMProviderKind.anthropic.rawValue, Text("Anthropic (Claude)")),
                    (LLMProviderKind.openAICompatible.rawValue, Text("OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…)")),
                ])
            }
            if provider == LLMProviderKind.anthropic.rawValue {
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
                    Label("Çalışıyor: \(reply)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
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
            MCPSettings()
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
            WebhookSettings(model: model)
            Text("Anahtarlar macOS Anahtar Zinciri'nde saklanır ve hiçbir zaman gösterilmez. Terminal'den eklediysen ilk kullanımda çıkan izin penceresinde \"Her Zaman İzin Ver\"i seç.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
    }
}

/// Not hazır olunca gönderilen webhook (Slack, Teams, Discord, Zapier, Make, n8n): adres Anahtar Zinciri'nde, kendiliğinden
/// gönderim ve deneme.
private struct WebhookSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.webhookAutoSend) private var autoSend: Bool = false
    @State private var testState: WebhookTestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "Bağlantılar")
            SecretField(title: "Webhook adresi", account: .webhook, onChange: { testState = .idle })
            SettingsRow(title: Text("Not hazır olunca gönder")) {
                Text("Slack, Microsoft Teams (iş akışı), Discord, Zapier, Make ya da n8n webhook adresi: her toplantının notu (özet, kararlar, görevler) oraya kendiliğinden gider. Toplantı sayfasındaki ⋯ menüsünden elle de gönderilebilir.")
                switch testState {
                case .idle:
                    EmptyView()
                case .running:
                    ProgressView().controlSize(.small)
                case .sent:
                    Label("Deneme notu gönderildi", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                }
            } control: {
                HStack(spacing: 8) {
                    Button("Dene") {
                        testState = .running
                        Task {
                            let error: String? = await model.sendTestWebhook()
                            testState = error.map { WebhookTestState.failed($0) } ?? .sent
                        }
                    }
                    .disabled(testState == .running)
                    Toggle("Not hazır olunca gönder", isOn: $autoSend)
                        .settingsToggle()
                }
            }
        }
    }
}

private enum WebhookTestState: Equatable {
    case idle
    case running
    case sent
    case failed(String)
}

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

/// Yerel MCP sunucusu: Claude Desktop, ChatGPT ya da başka MCP istemcisinin toplantı arşivini sorgulaması için
/// yapılandırma (uygulama `--mcp` ile pencere açmadan çalışır; veri Mac'ten çıkmaz, istemci yalnızca okur).
private struct MCPSettings: View {
    @State private var copied: Bool = false

    var body: some View {
        let path: String = Bundle.main.executablePath ?? "/Applications/AINotepad.app/Contents/MacOS/AINotepad"
        let config: String = """
        {
          "mcpServers": {
            "ai-notepad": {
              "command": "\(path)",
              "args": ["--mcp"]
            }
          }
        }
        """
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(title: "Yapay zekâ uygulamalarına bağla (MCP)")
            SettingsRow(title: Text("Claude Desktop, ChatGPT ve diğerleri")) {
                Text("Bu yapılandırmayı istemcinin MCP ayarlarına (Claude Desktop: Ayarlar › Geliştirici › Yapılandırmayı düzenle) ekle. İstemci toplantılarını listeler, arar, notları ve transkriptleri okur; yalnızca okur, hiçbir şey değiştirmez.")
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
                Label("Kullanılıyor: \(name). Bağlantıyı denemek için LLM sekmesi.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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

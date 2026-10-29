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
    case "tanilama": return .diagnostics
    #if HOSTED_EDITION
    case "hesap": return .account
    #endif
    default: return .general
    }
}

private enum SettingsSection: CaseIterable {
    #if HOSTED_EDITION
    /// Abonelik hesabı: giriş, deneme ya da abonelik, kullanım (bkz. App/Hosted).
    case account
    #endif
    case general
    case appearance
    case llm
    case keys
    case connections
    case shortcuts
    /// Sürüm, sistem, hesap, sunucuya erişim, izinler, model, güncelleme ve son hatalar (bkz. App/DiagnosticsViews.swift).
    case diagnostics

    /// Sekme çubuğundaki sekmeler: abonelik sürümünde LLM ve Anahtarlar yok (model ve anahtar sunucudadır).
    static var visible: [SettingsSection] {
        #if HOSTED_EDITION
        allCases.filter { (section: SettingsSection) -> Bool in section != .llm && section != .keys }
        #else
        allCases
        #endif
    }

    var title: LocalizedStringKey {
        switch self {
        #if HOSTED_EDITION
        case .account: "Hesap"
        #endif
        case .general: "Genel"
        case .appearance: "Görünüm"
        case .llm: "LLM"
        case .keys: "Anahtarlar"
        case .connections: "Bağlantılar"
        case .shortcuts: "Kısayollar"
        case .diagnostics: "Tanılama"
        }
    }
}

/// Ana penceredeki Ayarlar (ElevenLabs düzeni): büyük başlık, altı çizili sekmeler; her ayar ince çizgiyle ayrılmış bir
/// satır (solda başlık ve açıklama, sağda denetim).
struct SettingsPage: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController
    let updater: AppUpdater
    let crashReports: CrashReportCenter
    /// Karşılama ve kurulum ekranını yeniden açar.
    let onShowSetup: @MainActor () -> Void
    @State private var section: SettingsSection = launchSettingsSection(arguments: CommandLine.arguments)

    /// Başlığın altındaki özet: yalnızca bu sürümde görünen sekmeleri anar (abonelik sürümünde motor, model ve anahtar
    /// ayarı yok).
    private var settingsSubtitle: LocalizedStringKey {
        #if HOSTED_EDITION
        "Hesabını, arayüz dilini, görünümü, bağlantıları ve kısayolları yönet."
        #else
        "Arayüz dilini, tanıma motorunu, görünümü, yapay zekâ modellerini, anahtarları ve kısayolları yönet."
        #endif
    }

    #if HOSTED_EDITION
    /// İstenmişse Hesap sekmesini seçer ve isteği sıfırlar.
    private func selectAccountIfRequested() {
        guard router.opensAccountSettings else {
            return
        }
        router.opensAccountSettings = false
        section = .account
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Ayarlar")
                    .appFont(size: 30, weight: .regular)
                    .tracking(-0.5)
                Text(settingsSubtitle)
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 4)
                SettingsTabs(selection: $section)
                    .padding(.top, 20)
                Group {
                    switch section {
                    #if HOSTED_EDITION
                    // Giriş ya da çıkışta kurulum eksikleri uygulama düzeyinde yenilenir (bkz. AINotepadApp).
                    case .account:
                        HostedAccountSettings(account: .shared, isMeetingInFlight: model.isBusy || model.isStarting)
                    #endif
                    case .general: GeneralSettings(model: model, updater: updater, crashReports: crashReports, onShowSetup: onShowSetup)
                    case .appearance: AppearanceSettings()
                    case .llm: LLMSettings(model: model)
                    case .keys: KeySettings(model: model)
                    case .connections: ConnectionSettings(model: model)
                    case .shortcuts: ShortcutSettings(shortcuts: shortcuts)
                    case .diagnostics: DiagnosticsSettings(model: model, updater: updater)
                    }
                }
                .id(section)
                .transition(.opacity)
                .padding(.top, 8)
                #if HOSTED_EDITION
                // Kullanım göstergesi ya da bildirimi Ayarlar'ı Hesap sekmesinde açar.
                .onAppear { selectAccountIfRequested() }
                .onChange(of: router.opensAccountSettings) { (_: Bool, _: Bool) in selectAccountIfRequested() }
                #endif
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
                ForEach(SettingsSection.visible, id: \.self) { (item: SettingsSection) in
                    let isSelected: Bool = item == selection
                    Button {
                        selection = item
                    } label: {
                        // Sekme adı bölünmez (dar pencerede "Appearanc/e" oluyordu).
                        Text(item.title)
                            .appFont(size: 14, weight: isSelected ? .medium : .regular)
                            .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                            .lineLimit(1)
                            .fixedSize()
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

/// Arayüz ve not dili, motor, ad, canlı çeviri, mikrofon, "Ne kaçırdım?" süresi ve ses saklama süresi.
/// Tanıma sözlüğünün açıklaması: sözlüğün nerede uygulandığı sürüme göre (abonelikte motor seçimi yok).
private var vocabularyHelp: LocalizedStringKey {
    #if HOSTED_EDITION
    "Konuşma tanımanın doğru yazması gereken adlar, şirket ve ürün adları, kısaltmalar; satır başına bir tane (2–40 karakter, en fazla 5 sözcük; en fazla 30 kullanılır). Canlı metinde ve kayıt bitince yapılan son geçişte uygulanır. Toplantılarda verdiğin konuşmacı adları ve sözlük terimleri zaten kendiliğinden eklenir."
    #else
    "Konuşma tanımanın doğru yazması gereken adlar, şirket ve ürün adları, kısaltmalar; satır başına bir tane (2–40 karakter, en fazla 5 sözcük; en fazla 30 kullanılır). Bulut motorunda (Deepgram, ElevenLabs) uygulanır. Toplantılarda verdiğin konuşmacı adları ve sözlük terimleri zaten kendiliğinden eklenir."
    #endif
}

private struct GeneralSettings: View {
    let model: AppModel
    let updater: AppUpdater
    let crashReports: CrashReportCenter
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
    @AppStorage(SettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue
    @State private var interfaceLanguage: InterfaceLanguage = storedInterfaceLanguage()
    @State private var relaunchError: String?

    var body: some View {
        // Kayıt ya da toplantı işleme sürerken yeniden başlatılırsa o toplantı yarıda kalır.
        let isBusy: Bool = model.isBusy
        // Seçili not dilinin adı (arayüz dilinde): çeviri ayarlarında geçer.
        let noteLanguageName: String = storedNoteLanguage(value: noteLanguage).interfaceName
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: Text("Arayüz dili")) {
                Text("Menülerin ve ayarların dili.")
                if interfaceLanguage != launchInterfaceLanguage {
                    Text("Yeniden başlatınca uygulanır.").foregroundStyle(Theme.ink)
                }
                if let relaunchError {
                    NoticeText(relaunchError, severity: .error)
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
            SettingsRow(title: Text("Not ve çeviri dili")) {
                Text("Toplantı notları, canlı çeviri, \"Ne kaçırdım?\" özeti ve Sor cevapları bu dilde yazılır. Önceki notlar yazıldıkları dilde kalır.")
            } control: {
                SettingsMenu(selection: $noteLanguage, options: ShareLanguage.allCases.map { (language: ShareLanguage) -> (String, Text) in
                    (language.rawValue, Text(verbatim: language.nativeName))
                })
            }
            // Cihaz içi modelin bu dili yazıp yazamadığı uyarısı yenilensin.
            .onChange(of: noteLanguage) { (_: String, _: String) in
                model.settingsChanged()
            }
            #if !HOSTED_EDITION
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
                .disabled(model.isRecording || model.isStarting)
            }
            #endif
            SettingsRow(title: Text("Ana toplantı dili")) {
                Text("Otomatik dilde kayıt bu dille başlar; ilk dakikada konuşulan dil (35 dil) bulunup ona geçilir. Mac'te tanımada bu dil ile İngilizce arasında seçilir.")
            } control: {
                SettingsMenu(selection: $primaryLanguage, options: MeetingLanguage.allCases.map { (language: MeetingLanguage) -> (String, Text) in
                    (language.rawValue, Text(verbatim: languageName(language: language)))
                })
            }
            .onChange(of: primaryLanguage) { (_: String, _: String) in
                model.primaryLanguageChanged()
            }
            SettingsRow(title: Text("Kurulum")) {
                #if HOSTED_EDITION
                Text("İzinler, hesap ve kısayollar adım adım.")
                #else
                Text("İzinler, anahtarlar ve kısayollar adım adım.")
                #endif
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
                Text(vocabularyHelp)
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
                    NoticeText(error, severity: .error)
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
                        NoticeText(problem, severity: .attention)
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
            SettingsRow(title: Text("Kayıt sırasında \(noteLanguageName) diline çevir")) {
                Text(model.displayMode.needsLiveTranslation
                    ? "Her cümle kayıt sırasında \(noteLanguageName) diline çevrilir (LLM çağrısı); toplantı zaten bu dildeyse çevrilmez. Toplantı bitince \(noteLanguageName) not (görevler, kararlar, özet) hazırlanır."
                    : "Kayıt sırasında çeviri yapılmaz, yalnızca orijinal metin görünür. Toplantı bitince \(noteLanguageName) not (görevler, kararlar, özet) yine hazırlanır.")
            } control: {
                Toggle("Kayıt sırasında \(noteLanguageName) diline çevir", isOn: Binding<Bool>(
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
                        (DisplayMode.bilingual, Text("İki dil (orijinal + \(noteLanguageName))")),
                        (DisplayMode.turkishOnly, Text("Sadece \(noteLanguageName)")),
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
                    NoticeText(error, severity: .error)
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
            #if !HOSTED_EDITION
            // Abonelik sürümünde iCloud yetkisi yok (eşitleme geliştirici sürümünün kapsayıcısıyla karışmasın).
            CloudSyncRow(model: model)
            #endif
            UpdateSettingsRow(updater: updater)
            CrashReportsSettings(center: crashReports)
            FeedbackSettingsRow { await diagnosticsReportText(model: model, updater: updater) }
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
                NoticeText(message, severity: .error)
            case .idle:
                if model.cloudDownloadingCount > 0 {
                    Text("\(model.cloudDownloadingCount) toplantı iCloud'dan iniyor…").foregroundStyle(Theme.ink)
                }
            }
        } control: {
            Toggle("iCloud ile eşitle", isOn: Binding<Bool>(
                get: { model.cloud.location == .iCloud },
                set: { (enabled: Bool) -> Void in
                    Task {
                        if enabled {
                            await model.enableCloudSync()
                        } else {
                            await model.disableCloudSync()
                        }
                    }
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
                SettingsSlider(value: $uiScale, range: SettingsRange.uiScale, step: 0.05, minSymbol: "textformat.size.smaller", maxSymbol: "textformat.size.larger")
            }
            SettingsRow(title: Text("Metin boyutu: \(Int(textSize)) pt")) {
                Text("Canlı metin ve notlar.")
            } control: {
                SettingsSlider(value: $textSize, range: SettingsRange.textSize, step: 1, minSymbol: "textformat.size.smaller", maxSymbol: "textformat.size.larger")
            }
            SettingsRow(title: Text("Satır aralığı: \(Int(lineSpacing))")) {
                EmptyView()
            } control: {
                SettingsSlider(
                    value: $lineSpacing, range: SettingsRange.lineSpacing, step: 1,
                    minSymbol: "arrow.down.right.and.arrow.up.left", maxSymbol: "arrow.up.left.and.arrow.down.right"
                )
            }
            SettingsRow(title: Text("Alt boşluk: \(Int(bottomSpacing)) pt")) {
                EmptyView()
            } control: {
                SettingsSlider(
                    value: $bottomSpacing, range: SettingsRange.bottomSpacing, step: 4,
                    minSymbol: "arrow.down.right.and.arrow.up.left", maxSymbol: "arrow.up.left.and.arrow.down.right"
                )
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

/// Cihaz içi modelin (Apple Intelligence) durumu: kullanılabilirlik, ne yapılacağı, desteklenen diller ve ana toplantı
/// dili ya da not dili desteklenmiyorsa uyarı.
private struct OnDeviceLLMStatus: View {
    @AppStorage(SettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(SettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue

    var body: some View {
        switch onDeviceStatus() {
        case .success(let config):
            SettingsRow(title: Text("Apple Intelligence")) {
                Text("Not, çeviri ve soru bu cihazda yazılır: ücretsiz, anahtarsız, internetsiz. Model küçüktür (4 bin token bağlam): uzun toplantılar parça parça işlenir, not kendi anahtarınla seçilen modellerden daha kısa olur.")
            } control: {
                Label("Hazır", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
            }
            SettingsRow(title: Text("Desteklenen diller")) {
                Text(verbatim: onDeviceLanguageNames(config: config).joined(separator: ", "))
            } control: {
                EmptyView()
            }
            // Ana toplantı dili ya da not dili modelde yoksa uyarı.
            if let warning = MeetingLanguage(rawValue: primaryLanguage).flatMap({ (language: MeetingLanguage) -> String? in
                onDeviceModeWarning(config: config, primaryLanguage: language, outputLanguage: storedNoteLanguage(value: noteLanguage))
            }) {
                SettingsRow(title: Text("Ana toplantı dili")) {
                    Text(verbatim: warning)
                } control: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.muted)
                }
            }
        case .failure(let error):
            SettingsRow(title: Text("Apple Intelligence")) {
                Text(verbatim: userFacingMessage(error: error))
            } control: {
                Label("Kullanılamıyor", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.muted)
            }
        }
    }

    /// Modelin ayarı (kullanılabiliyorsa) ya da neden kullanılamadığı.
    private func onDeviceStatus() -> Result<OnDeviceConfig, any Error> {
        Result { () throws -> OnDeviceConfig in try onDeviceConfig() }
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
                    NoticeText(message, severity: .error)
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
        reply = try await sendLLM(provider: provider, request: translationRequest(sentence: connectionTestSentence(provider: provider), context: [], language: selectedNoteLanguage()))
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

/// Bağlantı denemesinde çevrilen cümle: Fince; cihaz içi model Fince anlamadığı için orada İngilizce. Saf fonksiyondur.
private func connectionTestSentence(provider: LLMProvider) -> String {
    guard case .onDevice = provider else {
        return "Hyvää huomenta."
    }
    return "Good morning."
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
                    NoticeText(message, severity: .error)
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

/// Bağlantılar: notların gittiği yerler (bağlı olanlar tek kartta, eklenebilenler marka renkli kartlarda), görev
/// araçları, yapay zekâ uygulamaları ve gelişmiş (beceriler, elle MCP yapılandırması). Uzun açıklamalar bilgi ipucunda.
private struct ConnectionSettings: View {
    let model: AppModel
    @State private var showsAdvanced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WebhookSettings(model: model)
            TaskTrackerSettings(model: model)
            ConnectionSectionHeader(
                title: "Yapay zekâ uygulamaları", subtitle: "Claude, Cursor ve VS Code toplantılarını arayıp okuyabilir.",
                info: "Bağlayınca uygulama toplantılarını listeleyip arar, notları ve transkriptleri okur; yalnızca okur, hiçbir şey değiştirmez. Okuduğunu kendi yapay zekâ sağlayıcısına gönderir."
            )
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 12) {
                ForEach(MCPClient.allCases, id: \.self) { (client: MCPClient) in
                    MCPClientCard(client: client)
                }
            }
            Button {
                withAnimation(.smooth(duration: 0.25)) { showsAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .appFont(size: 11, weight: .semibold)
                        .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                    Text("Gelişmiş: beceriler ve elle MCP yapılandırması").appFont(size: 13, weight: .medium)
                }
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .padding(.top, 30)
            if showsAdvanced {
                VStack(alignment: .leading, spacing: 0) {
                    SkillSettings(model: model)
                    MCPSettings()
                }
                .transition(.opacity)
            }
        }
    }
}

/// Bağlantı bölümünün başlığı: başlık, tek satır açıklama ve uzun açıklama için bilgi ipucu.
private struct ConnectionSectionHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let info: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .appFont(size: 18, weight: .semibold)
                    .tracking(-0.3)
                    .foregroundStyle(Theme.ink)
                Image(systemName: "info.circle")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .hoverHint(info, alignment: .leading, edge: .bottom)
            }
            Text(subtitle)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
        .padding(.top, 34)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Servisin işareti: kendi logosu (görsel kataloğunda, tek renk şablon) ya da logosu yoksa sistem simgesi.
private enum BrandMark {
    case logo(String)
    /// Yazıdan oluşan geniş logo (ör. Zoom): kutuyu daha çok doldurur.
    case wordmark(String)
    case symbol(String)
}

/// Servis kutusu: uygulamanın pastel film gradyanı üstünde servisin kendi logosu, koyu mürekkep renginde.
private struct BrandTile: View {
    let mark: BrandMark
    let palette: FilmPalette
    let seed: String
    let size: CGFloat

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Group {
            switch mark {
            case .logo(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.46, height: size * 0.46)
            case .wordmark(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.76, height: size * 0.76)
            case .symbol(let name):
                Image(systemName: name).appFont(size: size * 0.4, weight: .semibold)
            }
        }
        .foregroundStyle(Color.black.opacity(0.8))
        .frame(width: size, height: size)
        .background { FilmGradient(seed: "marka-\(seed)", palette: palette) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.2)))
        .accessibilityHidden(true)
    }
}

/// Bağlantı kartı: marka kutusu, ad, kısa açıklama, (varsa) "bağlı" rozeti ve sağda eylem.
private struct ConnectionCard<Action: View>: View {
    let tile: BrandTile
    let title: Text
    let detail: Text
    let badge: String?
    let action: Action

    init(tile: BrandTile, title: Text, detail: Text, badge: String?, @ViewBuilder action: () -> Action) {
        self.tile = tile
        self.title = title
        self.detail = detail
        self.badge = badge
        self.action = action()
    }

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 3) {
                // Uzun adlar (ör. "Folder (Obsidian, iCloud)") yanda iki düğme varken kesilmesin diye alta kayar.
                title
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // Rozet başlığın altında: yanında dururken uzun adları (İngilizcede) kesiyordu.
                if let badge {
                    Text(verbatim: badge)
                        .appFont(size: 10, weight: .semibold)
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }
                detail
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            // Düğmeler sıkıştırılmaz (dar kartta "Değiştir" iki satıra bölünüyordu); yer daralınca başlık kırılır.
            action
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(14)
        // Satırdaki en uzun kart kadar uzar: Apple Notlar'daki anahtar ya da iki satırlık açıklama yanındaki kartı
        // kısa bırakmasın.
        .frame(maxWidth: .infinity, minHeight: 70, maxHeight: .infinity, alignment: .leading)
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(Theme.line))
    }
}

/// Bir yapay zekâ uygulaması kartı: simgesi, adı, durumu; yüklüyse "Bağla" ya da (bağlıysa) "Kaldır". Yüklü değilse
/// soluk. Bağlayınca uygulamanın yapılandırma dosyasına AI-Notepad eklenir (diğer ayarlar korunur); uygulama yeniden
/// açılınca görünür.
private struct MCPClientCard: View {
    let client: MCPClient
    @State private var isConnected: Bool = false
    @State private var errorMessage: String?
    @State private var justConnected: Bool = false

    private var isInstalled: Bool {
        FileManager.default.fileExists(atPath: client.applicationPath)
    }

    private var tile: BrandTile {
        switch client {
        case .claudeDesktop: BrandTile(mark: .logo("brand-claude"), palette: .sunset, seed: "claude", size: 38)
        case .cursor: BrandTile(mark: .logo("brand-cursor"), palette: .mint, seed: "cursor", size: 38)
        case .vsCode: BrandTile(mark: .logo("brand-visualstudiocode"), palette: .ocean, seed: "vscode", size: 38)
        }
    }

    /// Yapılandırmaya yazılacak uygulama yolu; uygulama geçici konumdan çalışıyorsa hata.
    private func executablePath() throws -> String {
        guard let path = Bundle.main.executablePath else {
            throw MCPConfigError.writeFailed(path: Bundle.main.bundlePath, reason: "uygulamanın çalıştırılabilir dosyası bulunamadı")
        }
        return try mcpExecutablePath(executablePath: path)
    }

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                tile
                Spacer(minLength: 6)
                if isInstalled {
                    if isConnected {
                        Menu {
                            Button("Kaldır", role: .destructive) { disconnect() }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 16, height: 16)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.hoverCapsule)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Diğer işlemler")
                    } else {
                        Button("Bağla") { connect() }
                            .buttonStyle(.pillPrimary)
                            .controlSize(.small)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: client.displayName)
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Group {
                    if !isInstalled {
                        Text("Bu Mac'te yüklü değil").foregroundStyle(Theme.muted)
                    } else if let errorMessage {
                        NoticeText(errorMessage, severity: .error)
                    } else if isConnected {
                        Label(justConnected ? "Bağlandı — uygulamayı yeniden aç" : "Bağlı", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                    } else {
                        Text("Tek tıkla bağla").foregroundStyle(Theme.muted)
                    }
                }
                .appFont(size: 12, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(Theme.line))
        .opacity(isInstalled ? 1 : 0.55)
        .animation(.smooth(duration: 0.2), value: isConnected)
        .task { refresh() }
    }

    private func refresh() {
        guard isInstalled else {
            return
        }
        do {
            let config: JSONValue = try readMCPConfig(file: client.configFile(home: FileManager.default.homeDirectoryForCurrentUser))
            isConnected = isMCPServerConnected(config: config, client: client, executablePath: try executablePath(), serverName: mcpServerName(appName: appName))
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func connect() {
        do {
            try connectMCPClient(client: client, executablePath: try executablePath(), serverName: mcpServerName(appName: appName), home: FileManager.default.homeDirectoryForCurrentUser)
            justConnected = true
            refresh()
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func disconnect() {
        do {
            try disconnectMCPClient(client: client, serverName: mcpServerName(appName: appName), home: FileManager.default.homeDirectoryForCurrentUser)
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

    /// Servis kutusu: kendi logosu ve gradyan ailesi.
    var tile: BrandTile {
        switch self {
        case .slack: BrandTile(mark: .logo("brand-slack"), palette: .rose, seed: rawValue, size: 38)
        case .teams: BrandTile(mark: .logo("brand-microsoftteams"), palette: .violet, seed: rawValue, size: 38)
        case .discord: BrandTile(mark: .logo("brand-discord"), palette: .ocean, seed: rawValue, size: 38)
        case .notion: BrandTile(mark: .logo("brand-notion"), palette: .coral, seed: rawValue, size: 38)
        case .zoom: BrandTile(mark: .wordmark("brand-zoom"), palette: .ocean, seed: rawValue, size: 38)
        case .webhook: BrandTile(mark: .symbol("bolt.horizontal.fill"), palette: .mint, seed: rawValue, size: 38)
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
        case .discordSignIn: self == .discord
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

/// Kurulum sonucunun kendiliğinden kaybolma süresi: başarı 3,5 sn, hata 5 sn; diğer durumlar kalır. Saf fonksiyondur.
private func channelSetupFadeDelay(setup: ChannelSetup) -> Duration? {
    switch setup {
    case .done: .seconds(3.5)
    case .failed: .seconds(5)
    case .idle, .signingIn, .choosing, .pasting, .pastingZoom, .working: nil
    }
}

/// Kanallara gönder: bağlı hedefler (her birinin kendiliğinden gönderimi, dene, kanalı değiştir, yeniden bağlan,
/// kaldır), yeni hedef ekleme kartları (Slack, Teams, Discord, Notion, Zoom, webhook), Apple Notlar ve klasör. Birden
/// çok hedef aynı anda bağlı olabilir.
private struct WebhookSettings: View {
    let model: AppModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var setup: ChannelSetup = .idle
    /// Tarayıcıda süren Notion girişi: "Vazgeç" bunu iptal eder (yerel dönüş dinleyicisi kapanır).
    @State private var notionSignIn: Task<Void, Never>?
    @State private var selectedChannelID: String = ""
    @State private var manualAddress: String = ""
    @State private var zoomToken: String = ""
    @State private var notesStatus: String?
    @State private var folderStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConnectionSectionHeader(
                title: "Notların gittiği yerler", subtitle: "Not hazır olunca kanallara, Notion'a, Apple Notlar'a ya da klasöre gider.",
                info: "Her toplantının notu (önce görevler, sonra kararlar ve özet) bağladığın yerlere gider; her hedefte otomatik gönderimi ayrı açabilirsin. Toplantı sayfasındaki ⋯ menüsünden elle de gönderilir. Ağ yokken kaçan gönderimler sonra kendiliğinden gider."
            )
            if !model.destinations.isEmpty {
                connectedList.padding(.bottom, 16)
            }
            setupStatus
            // Dar alanda (İngilizce, büyük arayüz boyutu) tek sütuna iner: kartlar kesilmez.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(ChannelCard.allCases) { (card: ChannelCard) in
                    channelCard(card: card)
                }
                appleNotesCard
                folderCard
            }
            .padding(.vertical, 6)
        }
        .task { await model.loadDestinations() }
        .task(id: setup) { await fadeSetupResult(shown: setup) }
    }

    /// Bağlı hedefler tek kartta, ince çizgilerle ayrılmış satırlar.
    private var connectedList: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 0) {
            ForEach(Array(model.destinations.enumerated()), id: \.element.id) { (item: (offset: Int, element: NoteDestination)) in
                if item.offset > 0 {
                    SettingsDivider().padding(.leading, 64)
                }
                destinationRow(destination: item.element)
            }
        }
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(Theme.line))
    }

    /// Bağlı hedef: marka kutusu, ad ve kanal (ya da "yeniden bağlan" uyarısı), otomatik gönderim; dene, kanalı
    /// değiştir ve kaldır ⋯ menüsünde.
    private func destinationRow(destination: NoteDestination) -> some View {
        let card: ChannelCard = ChannelCard.allCases.first { $0.matches(destination: destination) } ?? .webhook
        return HStack(spacing: 12) {
            card.tile
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: destinationName(destination: destination))
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                if destination.needsReconnect {
                    NoticeText("Oturumun süresi doldu; yeniden bağlan", severity: .attention)
                        .appFont(size: 12, weight: .regular)
                } else {
                    Text(verbatim: destinationDetail(destination: destination))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if destination.needsReconnect {
                Button("Yeniden bağlan") {
                    switch destination.target {
                    case .account(let connection): Task { await signIn(service: connection.service, replacing: destination.id) }
                    case .notion: notionSignIn = Task { await reconnectNotion(destinationID: destination.id) }
                    case .webhook, .discordSignIn: return
                    }
                }
                .buttonStyle(.pillPrimary)
                .controlSize(.small)
            }
            Text("Otomatik gönder")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
            Toggle("Otomatik gönder", isOn: Binding<Bool>(
                get: { destination.autoSend },
                set: { (enabled: Bool) -> Void in Task { await model.setAutoSend(destinationID: destination.id, enabled: enabled) } }
            ))
            .settingsToggle()
            .hoverHint("Not hazır olunca kendiliğinden gönder", alignment: .trailing, edge: .bottom)
            Menu {
                Button("Deneme mesajı gönder", systemImage: "paperplane") { Task { await test(destinationID: destination.id) } }
                    .disabled(isBusy)
                if case .account(let connection) = destination.target, !destination.needsReconnect {
                    Button("Kanalı değiştir", systemImage: "arrow.left.arrow.right") {
                        Task { await changeChannel(destinationID: destination.id, service: connection.service) }
                    }
                    .disabled(isBusy)
                }
                Divider()
                Button("Kaldır", systemImage: "trash", role: .destructive) { Task { await model.removeDestination(id: destination.id) } }
            } label: {
                Image(systemName: "ellipsis").frame(width: 16, height: 16)
            }
            .menuStyle(.button)
            .buttonStyle(.hoverCapsule)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Diğer işlemler")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
                if let notionSignIn {
                    Button("Vazgeç") { notionSignIn.cancel() }
                }
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
            // Gönderim sürerken sakin bir nabız; yalnızca bu durumda çizilir, boştayken hiçbir şey kıpırdamaz.
            Label {
                Text(message)
            } icon: {
                Image(systemName: "paperplane").symbolEffect(.pulse)
            }
            .appFont(size: 13, weight: .regular)
            .padding(.bottom, 8)
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .appFont(size: 13, weight: .medium).foregroundStyle(.tint).padding(.bottom, 8)
                .transition(.opacity)
        case .failed(let message):
            NoticeText(message, severity: .error)
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
                .transition(.opacity)
        }
    }

    /// Sonuç mesajı (başarı ya da hata) bir süre sonra kendiliğinden yumuşakça kaybolur. Daha yeni bir durum gelince
    /// görev iptal olur, zamanlayıcı yeniden başlar.
    private func fadeSetupResult(shown: ChannelSetup) async {
        guard let delay = channelSetupFadeDelay(setup: shown) else {
            return
        }
        do {
            try await Task.sleep(for: delay)
        } catch {
            // Yalnızca iptal: yeni bir durum geldi, eski mesajın zamanlayıcısı bir şey silmez.
            return
        }
        guard setup == shown else {
            return
        }
        withAnimation(.easeOut(duration: 0.4)) { setup = .idle }
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
        return ConnectionCard(
            tile: card.tile, title: Text(verbatim: card.name), detail: Text(card.detail),
            badge: count > 0 ? String(localized: "\(count) bağlı") : nil
        ) {
            if count > 0 {
                Button("Ekle", systemImage: "plus") { start(card: card) }
                    .buttonStyle(.pill)
                    .controlSize(.small)
                    .disabled(isBusy)
                    .hoverHint("Başka bir kanal ya da hesap ekle", alignment: .trailing, edge: .bottom)
            } else {
                Button(card.service == nil && card != .notion ? "Yapıştır" : "Bağlan") { start(card: card) }
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
        ConnectionCard(
            tile: BrandTile(mark: .symbol("note.text"), palette: .coral, seed: "apple-notlar", size: 38), title: Text("Apple Notlar"),
            detail: notesStatus.map { Text(verbatim: $0) } ?? Text("\"\(appName)\" klasörüne, hesap gerekmez"), badge: nil
        ) {
            Toggle("Apple Notlar'a gönder", isOn: Binding<Bool>(
                get: { model.appleNotesAutoSend },
                set: { (enabled: Bool) -> Void in setNotesAutoSend(enabled: enabled) }
            ))
            .settingsToggle()
        }
    }

    /// Apple Notlar'a kendiliğinden gönderimi açar ya da kapatır. Açılınca izin penceresi çıksın ve doğru çalıştığı
    /// görülsün diye son not gönderilir; gönderilemezse ayar yeniden kapanır.
    private func setNotesAutoSend(enabled: Bool) {
        model.setAppleNotesAutoSend(enabled: enabled)
        guard enabled, let latest = model.meetings.first(where: { $0.note != nil }) else {
            return
        }
        Task {
            let error: String? = await model.sendToAppleNotes(meetingID: latest.id)
            notesStatus = error ?? String(localized: "Son not Notlar'a yazıldı.")
            if error != nil {
                model.setAppleNotesAutoSend(enabled: false)
            }
        }
    }

    private var folderCard: some View {
        let markdownFolder: String = model.markdownFolder
        return ConnectionCard(
            tile: BrandTile(mark: .symbol("folder.fill"), palette: .ocean, seed: "klasor", size: 38), title: Text("Klasör (Obsidian, iCloud)"),
            detail: folderStatus.map { Text(verbatim: $0) } ?? (markdownFolder.isEmpty ? Text("Markdown dosyası olarak") : Text(verbatim: (markdownFolder as NSString).abbreviatingWithTildeInPath)),
            badge: nil
        ) {
            if markdownFolder.isEmpty {
                Button("Seç…") { chooseFolder() }
                    .buttonStyle(.pillPrimary)
                    .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Button("Değiştir") { chooseFolder() }.controlSize(.small)
                    Toggle("Klasöre yaz", isOn: Binding<Bool>(
                        get: { model.markdownAutoExport },
                        set: { (enabled: Bool) -> Void in model.setMarkdownAutoExport(enabled: enabled) }
                    ))
                    .settingsToggle()
                }
            }
        }
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
            notionSignIn = Task { await connectNotion() }
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
                // Girişle oluşturulan webhook: hedef kaldırılınca Discord'da da silinir (yapıştırılan adresler silinmez).
                let destination: NoteDestination = try await model.addDestination(target: .discordSignIn(url))
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
        defer { notionSignIn = nil }
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

    /// Notion oturumu bitti: aynı hedefin bağlantısı yenilenir (ayarı ve gönderim geçmişi korunur).
    private func reconnectNotion(destinationID: String) async {
        setup = .signingIn("Notion")
        defer { notionSignIn = nil }
        do {
            try await model.reconnectNotion(destinationID: destinationID)
            setup = .done(String(localized: "Notion yeniden bağlandı."))
        } catch is CancellationError {
            setup = .idle
        } catch {
            channelSettingsLogger.error("Notion yeniden bağlanamadı, hata: \(String(describing: error), privacy: .private)")
            setup = .failed(userFacingMessage(error: error))
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
        guard let url = pickMarkdownFolder() else {
            return
        }
        model.setMarkdownFolder(path: url.path)
        model.setMarkdownAutoExport(enabled: true)
        folderStatus = model.meetings.first(where: { $0.note != nil }).flatMap { model.exportToFolder(meetingID: $0.id) }
            ?? String(localized: "Son not klasöre yazıldı.")
    }
}

/// Notların Markdown olarak yazılacağı klasörü sorar (Ayarlar › Bağlantılar ve toplantıdaki "Klasöre Markdown kaydet");
/// vazgeçilirse nil.
@MainActor
func pickMarkdownFolder() -> URL? {
    let panel: NSOpenPanel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "Seç")
    panel.message = String(localized: "Notların Markdown olarak yazılacağı klasör (ör. Obsidian kasası)")
    guard panel.runModal() == .OK, let url = panel.url else {
        return nil
    }
    return url
}

/// Görev araçları: Linear ve Jira'ya tek tıkla bağlanma (MCP, tarayıcıda izin; API anahtarı gerekmez), görevlerin
/// açılacağı takım ya da proje, kaldırma.
private struct TaskTrackerSettings: View {
    let model: AppModel
    @State private var status: String?
    @State private var connecting: MCPService?
    /// Tarayıcıda süren giriş: "Vazgeç" bunu iptal eder.
    @State private var signIn: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConnectionSectionHeader(
                title: "Görev araçları", subtitle: "Görevleri tek tıkla Linear ya da Jira'da iş olarak aç.",
                info: "Toplantı sayfası › ⋯ › Görevleri gönder. Bağlantı Linear ve Atlassian'ın resmi MCP sunucusuyla, tarayıcıda izin vererek kurulur; işleri yapay zekâ sağlayıcın açar."
            )
            // Dar alanda (İngilizce, büyük arayüz boyutu) tek sütuna iner: kartlar kesilmez.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach([MCPService.linear, MCPService.atlassian], id: \.self) { (service: MCPService) in
                    trackerCard(service: service)
                }
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

    private func tile(service: MCPService) -> BrandTile {
        service == .linear
            ? BrandTile(mark: .logo("brand-linear"), palette: .violet, seed: "linear", size: 38)
            : BrandTile(mark: .logo("brand-jira"), palette: .ocean, seed: "jira", size: 38)
    }

    /// Bağlı araçta takım/proje alanı ve ⋯ menüsünde kaldır; bağlı değilse "Bağlan" (girişte "Vazgeç").
    @ViewBuilder
    private func trackerCard(service: MCPService) -> some View {
        if let tracker = model.taskTrackers.first(where: { $0.service == service }) {
            ConnectionCard(tile: tile(service: service), title: Text(verbatim: service.displayName), detail: Text("Bağlı"), badge: nil) {
                HStack(spacing: 6) {
                    TrackerTargetPicker(model: model, tracker: tracker)
                    Menu {
                        Button("Kaldır", systemImage: "trash", role: .destructive) { Task { await model.removeTracker(id: tracker.id) } }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 16, height: 16)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.hoverCapsule)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Diğer işlemler")
                }
            }
        } else {
            ConnectionCard(
                tile: tile(service: service), title: Text(verbatim: service.displayName),
                detail: Text(service == .linear ? "Takımındaki işler" : "Jira projesindeki işler"), badge: nil
            ) {
                HStack(spacing: 6) {
                    if connecting == service, let signIn {
                        Button("Vazgeç") { signIn.cancel() }
                            .buttonStyle(.hoverPlain)
                            .foregroundStyle(Theme.muted)
                    }
                    Button(connecting == service ? "İzin bekleniyor…" : "Bağlan") { connect(service: service) }
                        .buttonStyle(.pillPrimary)
                        .controlSize(.small)
                        .disabled(connecting != nil)
                }
            }
        }
    }

    private func connect(service: MCPService) {
        connecting = service
        status = nil
        signIn = Task {
            defer {
                connecting = nil
                signIn = nil
            }
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

/// Görev aracının takım/proje alanı: yazarken değil, Return'de ya da alandan çıkınca kaydedilir (her tuşta Anahtar
/// Zinciri'ne yazılmasın, yazılan metin geri gelen eski değerle ezilmesin).
/// Görev aracının hedefi (Linear takımı, Jira projesi): araçtaki gerçek seçenekler menüde. Tek seçenek varsa yalnızca
/// adı görünür (seçilecek bir şey yok); hedef boşsa ilk seçenek kullanılır ve öyle gösterilir. Seçenekler okunamazsa
/// neden ve "Yeniden dene" görünür.
private struct TrackerTargetPicker: View {
    let model: AppModel
    let tracker: TaskTracker
    @State private var options: [String]?
    @State private var errorMessage: String?

    var body: some View {
        let noun: LocalizedStringKey = tracker.service == .atlassian ? "Proje" : "Takım"
        let current: String? = tracker.target.isEmpty ? options?.first : tracker.target
        Group {
            if let options, options.count > 1 {
                Menu {
                    ForEach(options, id: \.self) { (name: String) in
                        Button {
                            Task { await model.setTrackerTarget(id: tracker.id, target: name) }
                        } label: {
                            if name == current {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(verbatim: name)
                            }
                        }
                    }
                } label: {
                    targetLabel(noun: noun, name: current ?? "")
                }
                .menuStyle(.button)
                .buttonStyle(.pill)
                .controlSize(.small)
                .fixedSize()
            } else if let current {
                targetLabel(noun: noun, name: current)
                    .foregroundStyle(Theme.muted)
            } else if let errorMessage {
                Button("Yeniden dene", systemImage: "arrow.clockwise") { Task { await load() } }
                    .controlSize(.small)
                    .hoverHint(verbatim: errorMessage, alignment: .trailing, edge: .bottom)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: tracker.id) { await load() }
    }

    private func targetLabel(noun: LocalizedStringKey, name: String) -> some View {
        HStack(spacing: 4) {
            Text(noun).foregroundStyle(Theme.muted)
            Text(verbatim: name).lineLimit(1)
        }
        .appFont(size: 12, weight: .medium)
    }

    private func load() async {
        errorMessage = nil
        do {
            options = try await model.trackerTargets(id: tracker.id)
        } catch {
            errorMessage = userFacingMessage(error: error)
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
                        NoticeText(error, severity: .error)
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

/// Ayar kaydırıcısı: iki ucunda küçük ve büyük ucu gösteren soluk simgeler, hepsinde aynı genişlik (Görünüm'deki
/// kaydırıcılar alt alta hizalı dursun).
private struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let minSymbol: String
    let maxSymbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: minSymbol)
                .foregroundStyle(Theme.muted)
                .frame(width: 18)
                .accessibilityHidden(true)
            Slider(value: $value, in: range, step: step).frame(width: 220)
            Image(systemName: maxSymbol)
                .foregroundStyle(Theme.muted)
                .frame(width: 18)
                .accessibilityHidden(true)
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

/// JSON metin değeri: tırnak ve ters bölü kaçışlanır (tırnak ya da ters bölü içeren yol yapılandırmayı bozmasın).
/// Saf fonksiyondur.
private func jsonStringLiteral(text: String) -> String {
    "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
}

/// İstemcinin MCP yapılandırması: sunucu adı sürüme özgüdür (bkz. `mcpServerName(appName:)`), tek tıkla bağlamanın
/// yazdığıyla aynıdır. Saf fonksiyondur.
func mcpClientConfig(executablePath: String, serverName: String) -> String {
    """
    {
      "mcpServers": {
        \(jsonStringLiteral(text: serverName)): {
          "command": \(jsonStringLiteral(text: executablePath)),
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
        let config: String = mcpClientConfig(
            executablePath: Bundle.main.executableURL?.path ?? Bundle.main.bundlePath, serverName: mcpServerName(appName: appName)
        )
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
                NoticeText("Ollama bulunamadı (\(message)). ollama.com'dan kur, sonra Terminal'de: ollama pull gpt-oss:20b", severity: .attention)
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

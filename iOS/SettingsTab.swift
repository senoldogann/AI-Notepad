import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar: görünüm, iCloud eşitlemesi, bulut anahtarları, kayıt (rıza hatırlatması, ses saklama), takvim, toplantı
/// dili ve ad, sürüm.
struct PhoneSettingsTab: View {
    let store: PhoneStore
    let calendar: PhoneCalendar
    /// Kayıttaki, işlenen ve çalan toplantılar: eşitleme açılıp kapanırken taşınmaz.
    let excludedFromMoves: Set<String>
    let crashReports: CrashReportCenter
    @AppStorage(PhoneSettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(PhoneSettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue
    @AppStorage(PhoneSettingsKey.userName) private var userName: String = ""
    @AppStorage(PhoneSettingsKey.consentReminder) private var consentReminder: Bool = true
    @AppStorage(PhoneSettingsKey.audioRetentionDays) private var retentionDays: Int = 30
    @AppStorage(PhoneSettingsKey.theme) private var theme: String = AppTheme.system.rawValue
    @AppStorage(PhoneSettingsKey.engine) private var engine: String = PhoneEngine.cloud.rawValue
    @AppStorage(PhoneSettingsKey.designStyle) private var designStyle: String = DesignLook.standard.style.rawValue
    @AppStorage(PhoneSettingsKey.glassTint) private var glassTint: String = DesignLook.standard.tint.rawValue

    var body: some View {
        NavigationStack {
            List {
                CrashReportNotice(center: crashReports)
                Section {
                    Picker("Yazıya dökme ve not", selection: $engine) {
                        Text("Cihaz içi (ücretsiz, anahtarsız)").tag(PhoneEngine.onDevice.rawValue)
                        Text("Bulut (kendi anahtarlarınla)").tag(PhoneEngine.cloud.rawValue)
                    }
                    if engine == PhoneEngine.onDevice.rawValue, let problem = onDeviceProblem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Motor")
                } footer: {
                    Text(engine == PhoneEngine.onDevice.rawValue
                        ? "Apple'ın konuşma tanıması ve Apple Intelligence: ses ve metin telefondan çıkmaz. Konuşmacılar ayrılmaz; not, bulut modellerinden daha kısadır."
                        : "Deepgram canlı metni, ElevenLabs konuşmacıları, Claude notu yazar; aşağıdaki anahtarlar gerekir.")
                }
                Section {
                    Picker("Tema", selection: $theme) {
                        ForEach(AppTheme.allCases, id: \.self) { (item: AppTheme) in
                            Text(verbatim: item.displayName).tag(item.rawValue)
                        }
                    }
                    Picker("Stil", selection: $designStyle) {
                        Text("Standart").tag(DesignStyle.standard.rawValue)
                        Text("Liquid Glass").tag(DesignStyle.liquidGlass.rawValue)
                    }
                    if designStyle == DesignStyle.liquidGlass.rawValue {
                        PhoneGlassTintPicker(selection: $glassTint)
                    }
                } header: {
                    Text("Görünüm")
                }
                Section {
                    Toggle("iCloud ile eşitle", isOn: Binding<Bool>(
                        get: { store.cloud.location == .iCloud },
                        set: { (enabled: Bool) -> Void in
                            Task {
                                if enabled {
                                    await store.cloud.enable(excluding: excludedFromMoves) { store.reload() }
                                } else {
                                    await store.cloud.disable { store.reload() }
                                }
                            }
                        }
                    ))
                    .disabled(store.cloud.state == .working)
                    switch store.cloud.state {
                    case .working:
                        Label("Toplantılar taşınıyor…", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Theme.muted)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    case .idle:
                        if store.downloadingCount > 0 {
                            Label("\(store.downloadingCount) toplantı iCloud'dan iniyor…", systemImage: "icloud.and.arrow.down")
                                .foregroundStyle(Theme.muted)
                        }
                    }
                } header: {
                    Text("Eşitleme")
                } footer: {
                    Text("Biten toplantılar iCloud Drive'a taşınır ve Mac'teki AI-Notepad'de de görünür (Mac'te de açık olmalı). Kayıt ve işleme bu iPhone'da yapılır. Kapatınca iCloud'daki toplantıların bir kopyası bu iPhone'da kalır; Mac'tekiler etkilenmez.")
                }
                Section {
                    KeyRow(account: .deepgram, title: "Deepgram", purpose: "Canlı metin")
                    KeyRow(account: .elevenlabs, title: "ElevenLabs", purpose: "Konuşmacılar ve son geçiş")
                    KeyRow(account: .anthropic, title: "Anthropic (Claude)", purpose: "Çeviri ve not")
                } header: {
                    Text("Anahtarlar")
                } footer: {
                    Text("Mac'te Ayarlar › Anahtarlar › \"iPhone'a gönder\" dersen anahtarlar iCloud Anahtar Zinciri ile buraya gelir. Burada girdiğin anahtar yalnız bu iPhone'da saklanır ve öncelik onundur.")
                }
                Section {
                    Toggle("Kayıt başlarken haber vermeyi hatırlat", isOn: $consentReminder)
                    Picker("Sesleri sakla", selection: $retentionDays) {
                        ForEach([7, 14, 30, 60, 90, 180, 365], id: \.self) { (days: Int) in
                            Text("\(days) gün").tag(days)
                        }
                    }
                    .onChange(of: retentionDays) { (_: Int, _: Int) in
                        store.applyRetention(now: Date())
                    }
                } header: {
                    Text("Kayıt")
                } footer: {
                    Text("Kayıttan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur. Süre dolunca ses dosyaları silinir, metin ve not kalır; yarıda kalan ya da başarısız toplantının sesi iki kat süre saklanır.")
                }
                CalendarSettingsSection(calendar: calendar)
                Section {
                    Picker("Ana toplantı dili", selection: $primaryLanguage) {
                        ForEach(MeetingLanguage.allCases, id: \.rawValue) { (language: MeetingLanguage) in
                            Text(languageName(language: language)).tag(language.rawValue)
                        }
                    }
                    Picker("Not ve çeviri dili", selection: $noteLanguage) {
                        ForEach(ShareLanguage.allCases, id: \.rawValue) { (language: ShareLanguage) in
                            Text(verbatim: language.nativeName).tag(language.rawValue)
                        }
                    }
                    TextField("Adın (notta senin görevlerin için)", text: $userName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Toplantı")
                } footer: {
                    Text("Toplantı notları, canlı çeviri ve Sor cevapları not ve çeviri dilinde yazılır; toplantı zaten bu dildeyse çevrilmez. Önceki notlar yazıldıkları dilde kalır.")
                }
                Section("Uygulama") {
                    LabeledContent("Sürüm", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("Toplantılar", value: "\(store.meetings.count)")
                    CrashReportsLink(center: crashReports)
                }
            }
            .navigationTitle("Ayarlar")
        }
    }

    /// Cihaz içi model kullanılamıyorsa ya da ana toplantı dilini desteklemiyorsa ne yapılacağı; sorun yoksa nil.
    private var onDeviceProblem: String? {
        do {
            let config: OnDeviceConfig = try onDeviceConfig()
            return onDeviceModeWarning(config: config, primaryLanguage: phonePrimaryMeetingLanguage(), outputLanguage: phoneStoredNoteLanguage(value: noteLanguage))
        } catch {
            return userFacingMessage(error: error)
        }
    }
}

/// Liquid Glass'ın cam rengi: başlık, seçili rengin adı ve altında cam örnekleri (Mac'teki Görünüm ayarıyla aynı).
private struct PhoneGlassTintPicker: View {
    @Binding var selection: String

    var body: some View {
        let selected: GlassTint = GlassTint(rawValue: selection) ?? DesignLook.standard.tint
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cam rengi")
                Spacer()
                Text(verbatim: selected.displayName).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(GlassTint.allCases, id: \.self) { (item: GlassTint) in
                    GlassTintSwatch(tint: item, isSelected: item == selected, accent: PanelAppearance.standard.accent.color) { selection = item.rawValue }
                }
            }
            .glassGroup(spacing: 8)
        }
        .padding(.vertical, 4)
    }
}

/// Takvim: varsayılan kapalı; açılınca iOS izni sorar. İzin yoksa nedeni ve iPhone Ayarları'na giden düğme görünür.
private struct CalendarSettingsSection: View {
    let calendar: PhoneCalendar
    @AppStorage(PhoneSettingsKey.calendarEnabled) private var isEnabled: Bool = false
    /// İzin isteniyor (iOS sorusu açık).
    @State private var isRequesting: Bool = false
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        Section {
            Toggle("Takvimi kullan", isOn: Binding<Bool>(
                get: { isEnabled },
                set: { (enabled: Bool) -> Void in
                    guard enabled else {
                        calendar.disable()
                        return
                    }
                    isRequesting = true
                    Task {
                        await calendar.enable()
                        isRequesting = false
                    }
                }
            ))
            .disabled(isRequesting)
            switch calendar.state {
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Takvime erişim izni yok. iPhone Ayarları › Gizlilik ve Güvenlik › Takvimler'den AI-Notepad'e tam erişim ver.", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("Ayarlar'ı aç") { openURL(url) }
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .off, .on:
                EmptyView()
            }
        } header: {
            Text("Takvim")
        } footer: {
            Text("Kayıt ekranında sıradaki toplantılar görünür; süren bir toplantıda başlattığın kayıt onun adını ve katılımcılarını alır (adlar tanımaya da yardım eder).")
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
    /// Mac'ten iCloud Anahtar Zinciri ile gelen kopya var.
    @State private var isFromMac: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appFont(size: 15, weight: .medium)
                    Text(purpose).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                }
                Spacer()
                if isFromMac {
                    Label("Mac'ten", systemImage: "icloud.fill")
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(.tint)
                } else if isSaved {
                    Label("Kayıtlı", systemImage: "checkmark.circle.fill")
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(.tint)
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
            // Hem bu iPhone'daki hem Mac'ten gelen kopya silinir (yoksa Mac'inki "Kayıtlı" kalırdı).
            try deleteSecret(service: keychainService, account: account)
            try deleteSyncedSecret(service: keychainService, account: account)
            refresh()
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func refresh() {
        do {
            // "Mac'ten" yalnızca kullanılan kopya Mac'inkiyse (burada girilen öncelikli).
            let hasLocal: Bool = try localSecretExists(service: keychainService, account: account)
            let hasSynced: Bool = try syncedSecretExists(service: keychainService, account: account)
            isFromMac = !hasLocal && hasSynced
            isSaved = hasLocal || isFromMac
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

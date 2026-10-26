import AINotepadCore
import AppKit
import Carbon.HIToolbox
import Observation
import os

private let hotKeyLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HotKeys")

/// Kısayol kaydı başarısız oldu (ör. başka bir uygulama aynı kısayolu kullanıyor).
enum HotKeyError: Error, Equatable {
    case handlerInstallFailed(status: Int32)
    case registrationFailed(keyCode: UInt32, status: Int32)
    case systemShortcutsUnreadable(status: Int32)
    /// Aynı kısayol etkin bir macOS sistem kısayolu (ör. giriş kaynağı değiştirme); sistem önce davranır.
    case conflictsWithSystemShortcut(keyCode: UInt32, modifiers: UInt32)
    /// Yalnızca ⇧ ya da değiştiricisiz harf: yazı yazarken tetiklenirdi.
    case unusableBinding(keyCode: UInt32, modifiers: UInt32)
    /// Aynı kısayol bu uygulamada başka bir eyleme atanmış.
    case duplicate(keyCode: UInt32, modifiers: UInt32)
}

/// Kısayolla tetiklenen eylemler.
enum ShortcutAction: String, CaseIterable {
    case record
    case toggleWindows

    var title: String {
        switch self {
        case .record: "Kaydı başlat / durdur"
        case .toggleWindows: "Ada ve paneli göster / gizle"
        }
    }

    var settingsKey: String {
        switch self {
        case .record: SettingsKey.recordShortcut
        case .toggleWindows: SettingsKey.windowsShortcut
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .record: defaultRecordBinding
        case .toggleWindows: defaultWindowsBinding
        }
    }
}

/// Uygulama öndeyken de değilken çalışan global kısayollar (Carbon; erişilebilirlik izni gerektirmez).
/// Her eylemin tek kısayolu vardır; yeniden atanınca eskisi bırakılır.
@MainActor
final class HotKeyCenter {
    /// 'AINP' imzası: kısayol olaylarını bu uygulamanınkilerle eşler.
    fileprivate nonisolated static let signature: OSType = 0x41494E50

    private struct Registration {
        let id: UInt32
        let binding: KeyBinding
        let reference: EventHotKeyRef
        let action: @MainActor () -> Void
    }

    private var registrations: [ShortcutAction: Registration] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {}

    /// Eylemin kısayolunu kaydeder (varsa eskisini bırakır); tuşa basılınca `action` ana aktörde çalışır.
    /// Kullanılamayan, sistem kısayoluyla çakışan ya da başka uygulamanın özel kaydettiği kısayolda hata fırlatır
    /// ve eski kısayol çalışmaya devam eder.
    func bind(action: ShortcutAction, binding: KeyBinding, handler perform: @escaping @MainActor () -> Void) throws {
        guard isUsableGlobalBinding(binding: binding) else {
            throw HotKeyError.unusableBinding(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
        if registrations.contains(where: { $0.key != action && $0.value.binding == binding }) {
            throw HotKeyError.duplicate(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
        if isTakenBySystem(keyCode: binding.keyCode, modifiers: binding.modifiers, systemShortcuts: try systemShortcuts()) {
            throw HotKeyError.conflictsWithSystemShortcut(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
        try installHandlerIfNeeded()
        let previous: Registration? = registrations[action]
        // Aynı kısayol yeniden kaydedilecekse önce bırakılır (aksi halde özel kayıt kendisiyle çakışır).
        if let previous, previous.binding == binding {
            unregister(registration: previous)
        }
        let id: UInt32 = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status: OSStatus = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            // Başka bir uygulama aynı kısayolu kullanıyorsa kayıt başarısız olsun (sessizce paylaşılmasın).
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else {
            throw HotKeyError.registrationFailed(keyCode: binding.keyCode, status: status)
        }
        if let previous, previous.binding != binding {
            unregister(registration: previous)
        }
        registrations[action] = Registration(id: id, binding: binding, reference: reference, action: perform)
        hotKeyLogger.info("Kısayol kaydedildi, eylem: \(action.rawValue, privacy: .public), tuş: \(binding.keyCode, privacy: .public), değiştirici: \(binding.modifiers, privacy: .public)")
    }

    /// Eylemin çalışan kısayolu.
    func binding(action: ShortcutAction) -> KeyBinding? {
        registrations[action]?.binding
    }

    /// Tüm kısayolları ve olay işleyicisini bırakır (uygulama kapanırken).
    func unregisterAll() {
        for registration in registrations.values {
            unregister(registration: registration)
        }
        registrations = [:]
        if let handler {
            let status: OSStatus = RemoveEventHandler(handler)
            if status != noErr {
                hotKeyLogger.error("Kısayol işleyicisi kaldırılamadı, durum: \(status, privacy: .public)")
            }
        }
        handler = nil
    }

    private func unregister(registration: Registration) {
        let status: OSStatus = UnregisterEventHotKey(registration.reference)
        if status != noErr {
            hotKeyLogger.error("Kısayol bırakılamadı, kimlik: \(registration.id, privacy: .public), durum: \(status, privacy: .public)")
        }
        registrations = registrations.filter { $0.value.id != registration.id }
    }

    /// Etkin/pasif tüm macOS sistem kısayolları.
    private func systemShortcuts() throws -> [SystemShortcut] {
        var list: Unmanaged<CFArray>?
        let status: OSStatus = CopySymbolicHotKeys(&list)
        guard status == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else {
            throw HotKeyError.systemShortcutsUnreadable(status: status)
        }
        return entries.compactMap { (entry: [String: Any]) -> SystemShortcut? in
            guard let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                  let enabled = entry[kHISymbolicHotKeyEnabled as String] as? Bool
            else {
                return nil
            }
            return SystemShortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers), isEnabled: enabled)
        }
    }

    fileprivate func fire(id: UInt32) {
        guard let registration = registrations.values.first(where: { $0.id == id }) else {
            hotKeyLogger.error("Bilinmeyen kısayol kimliği: \(id, privacy: .public)")
            return
        }
        hotKeyLogger.info("Kısayol tetiklendi, kimlik: \(id, privacy: .public)")
        registration.action()
    }

    private func installHandlerIfNeeded() throws {
        guard handler == nil else {
            return
        }
        var eventType: EventTypeSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status: OSStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else {
            throw HotKeyError.handlerInstallFailed(status: status)
        }
    }
}

/// Carbon kısayol geri çağrısı; ana iş parçacığında çağrılır. Başka imzalı olaylar bu uygulamanın değildir.
private let hotKeyCallback: EventHandlerUPP = { (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }
    var hotKeyID: EventHotKeyID = EventHotKeyID()
    let status: OSStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else {
        return status
    }
    guard hotKeyID.signature == HotKeyCenter.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let center: HotKeyCenter = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        center.fire(id: hotKeyID.id)
    }
    return noErr
}

/// Kısayolun kullanıcıya gösterilecek hata metni.
func shortcutErrorMessage(error: any Error, binding: KeyBinding) -> String {
    let name: String = keyBindingDisplay(binding: binding)
    switch error {
    case HotKeyError.conflictsWithSystemShortcut:
        return "\(name) bir macOS sistem kısayolu; başka bir kısayol seç."
    case HotKeyError.unusableBinding:
        return "\(name) kullanılamaz: ⌃, ⌥ ya da ⌘ ile birlikte bir harf/rakam seç."
    case HotKeyError.duplicate:
        return "\(name) diğer eyleme atanmış."
    case HotKeyError.registrationFailed:
        return "\(name) başka bir uygulamada kullanılıyor."
    default:
        return "\(name) kaydedilemedi."
    }
}

/// Kısayolları ayarlardan kurar ve Ayarlar'dan değiştirir; hataları menüde gösterilmek üzere modele yazar.
@MainActor
@Observable
final class ShortcutController {
    private let hotKeys: HotKeyCenter
    private let model: AppModel
    private let actions: [ShortcutAction: @MainActor () -> Void]
    /// Eylem başına son hata (Ayarlar'da gösterilir).
    var errors: [ShortcutAction: String] = [:]

    init(hotKeys: HotKeyCenter, model: AppModel, actions: [ShortcutAction: @MainActor () -> Void]) {
        self.hotKeys = hotKeys
        self.model = model
        self.actions = actions
    }

    /// Kayıtlı (ya da varsayılan) kısayolları kurar.
    func registerAll() {
        for action in ShortcutAction.allCases {
            apply(action: action, binding: storedKeyBinding(key: action.settingsKey, fallback: action.defaultBinding))
        }
    }

    /// Çalışan kısayol; kurulamadıysa kayıtlı olan.
    func currentBinding(action: ShortcutAction) -> KeyBinding {
        hotKeys.binding(action: action) ?? storedKeyBinding(key: action.settingsKey, fallback: action.defaultBinding)
    }

    /// Yeni kısayolu dener; başarılıysa kaydeder. Başarısızsa eski kısayol çalışmaya devam eder.
    func change(action: ShortcutAction, binding: KeyBinding) {
        apply(action: action, binding: binding)
        guard errors[action] == nil else {
            return
        }
        do {
            try storeKeyBinding(key: action.settingsKey, binding: binding)
        } catch {
            errors[action] = "Kısayol kaydedilemedi: \(error.localizedDescription)"
        }
        publish()
    }

    private func apply(action: ShortcutAction, binding: KeyBinding) {
        guard let perform = actions[action] else {
            return
        }
        do {
            try hotKeys.bind(action: action, binding: binding, handler: perform)
            errors[action] = nil
        } catch {
            hotKeyLogger.error("Kısayol kurulamadı, eylem: \(action.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            errors[action] = shortcutErrorMessage(error: error, binding: binding)
        }
        publish()
    }

    /// Menüdeki kırmızı satır.
    private func publish() {
        let messages: [String] = ShortcutAction.allCases.compactMap { errors[$0] }
        model.shortcutError = messages.isEmpty ? nil : "Kısayol çalışmıyor: " + messages.joined(separator: " ")
    }
}

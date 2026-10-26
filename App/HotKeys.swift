import AINotepadCore
import AppKit
import Carbon.HIToolbox
import os

private let hotKeyLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HotKeys")

/// Kısayol kaydı başarısız oldu (ör. başka bir uygulama aynı kısayolu kullanıyor).
enum HotKeyError: Error, Equatable {
    case handlerInstallFailed(status: Int32)
    case registrationFailed(keyCode: UInt32, status: Int32)
    /// Aynı kısayol etkin bir macOS sistem kısayolu (ör. giriş kaynağı değiştirme); sistem önce davranır.
    case conflictsWithSystemShortcut(keyCode: UInt32, modifiers: UInt32)
}

/// Uygulama öndeyken de değilken çalışan global kısayollar (Carbon; erişilebilirlik izni gerektirmez).
@MainActor
final class HotKeyCenter {
    /// 'AINP' imzası: kısayol olaylarını bu uygulamanınkilerle eşler.
    private static let signature: OSType = 0x41494E50

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {}

    /// Kısayolu kaydeder; tuşa basılınca `action` ana aktörde çalışır.
    /// Sistem kısayoluyla çakışırsa ya da başka uygulama aynı kısayolu özel kaydettiyse hata fırlatır.
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) throws {
        if isTakenBySystem(keyCode: keyCode, modifiers: modifiers, systemShortcuts: try systemShortcuts()) {
            throw HotKeyError.conflictsWithSystemShortcut(keyCode: keyCode, modifiers: modifiers)
        }
        try installHandlerIfNeeded()
        let id: UInt32 = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status: OSStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            // Başka bir uygulama aynı kısayolu kullanıyorsa kayıt başarısız olsun (sessizce paylaşılmasın).
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else {
            throw HotKeyError.registrationFailed(keyCode: keyCode, status: status)
        }
        references.append(reference)
        actions[id] = action
        hotKeyLogger.info("Kısayol kaydedildi, tuş: \(keyCode, privacy: .public), değiştirici: \(modifiers, privacy: .public)")
    }

    /// Etkin/pasif tüm macOS sistem kısayolları.
    private func systemShortcuts() throws -> [SystemShortcut] {
        var list: Unmanaged<CFArray>?
        let status: OSStatus = CopySymbolicHotKeys(&list)
        guard status == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else {
            throw HotKeyError.registrationFailed(keyCode: 0, status: status)
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
        hotKeyLogger.info("Kısayol tetiklendi: \(id, privacy: .public)")
        actions[id]?()
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

/// Carbon kısayol geri çağrısı; ana iş parçacığında çağrılır.
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
    let center: HotKeyCenter = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        center.fire(id: hotKeyID.id)
    }
    return noErr
}

/// ⌃⌥R (kayıt) ve ⌃⌥P (pencereler) tuş kodları ve değiştiricileri.
/// ⌃⌥Space kullanılmaz: macOS'ta "sonraki giriş kaynağı" sistem kısayoludur.
enum Shortcut {
    static let modifiers: UInt32 = UInt32(controlKey | optionKey)
    static let record: UInt32 = UInt32(kVK_ANSI_R)
    static let toggleWindows: UInt32 = UInt32(kVK_ANSI_P)
}

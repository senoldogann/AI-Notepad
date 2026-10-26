import AppKit
import Carbon.HIToolbox
import os

private let hotKeyLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HotKeys")

/// Kısayol kaydı başarısız oldu (ör. başka bir uygulama aynı kısayolu kullanıyor).
enum HotKeyError: Error, Equatable {
    case handlerInstallFailed(status: Int32)
    case registrationFailed(keyCode: UInt32, status: Int32)
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
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) throws {
        try installHandlerIfNeeded()
        let id: UInt32 = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status: OSStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw HotKeyError.registrationFailed(keyCode: keyCode, status: status)
        }
        references.append(reference)
        actions[id] = action
        hotKeyLogger.info("Kısayol kaydedildi, tuş: \(keyCode, privacy: .public), değiştirici: \(modifiers, privacy: .public)")
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

/// ⌃⌥R ve ⌃⌥Space tuş kodları ve değiştiricileri.
enum Shortcut {
    static let modifiers: UInt32 = UInt32(controlKey | optionKey)
    static let record: UInt32 = UInt32(kVK_ANSI_R)
    static let toggleWindows: UInt32 = UInt32(kVK_Space)
}

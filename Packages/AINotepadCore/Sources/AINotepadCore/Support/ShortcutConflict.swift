import Foundation

/// macOS sistem kısayolu (Carbon `CopySymbolicHotKeys` biçimi: sanal tuş kodu + Carbon değiştiricileri).
public struct SystemShortcut: Sendable, Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let isEnabled: Bool

    public init(keyCode: UInt32, modifiers: UInt32, isEnabled: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }
}

/// Karşılaştırmada dikkate alınan Carbon değiştiricileri: ⌘ 0x100, ⇧ 0x200, ⌥ 0x800, ⌃ 0x1000.
let relevantModifierMask: UInt32 = 0x100 | 0x200 | 0x800 | 0x1000

/// Kısayol etkin bir sistem kısayoluyla aynı mı (sistem önce davrandığı için uygulamaya ulaşmaz). Saf fonksiyondur.
public func isTakenBySystem(keyCode: UInt32, modifiers: UInt32, systemShortcuts: [SystemShortcut]) -> Bool {
    systemShortcuts.contains { (shortcut: SystemShortcut) -> Bool in
        shortcut.isEnabled
            && shortcut.keyCode == keyCode
            && shortcut.modifiers & relevantModifierMask == modifiers & relevantModifierMask
    }
}

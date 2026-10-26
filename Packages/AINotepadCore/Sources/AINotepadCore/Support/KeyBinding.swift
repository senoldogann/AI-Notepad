import Foundation

/// Global kısayol: Carbon tuş kodu + Carbon değiştirici maskesi (`controlKey`, `optionKey`…).
public struct KeyBinding: Sendable, Equatable, Codable, Hashable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Carbon değiştirici bitleri (`Carbon.HIToolbox`'taki `cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
public enum CarbonModifier {
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
}

/// Varsayılan kısayollar: ⌃⌥R kayıt, ⌃⌥P pencereler (⌃⌥Space macOS'ta giriş kaynağı kısayoludur).
public let defaultRecordBinding: KeyBinding = KeyBinding(keyCode: 0x0F, modifiers: CarbonModifier.control | CarbonModifier.option)
public let defaultWindowsBinding: KeyBinding = KeyBinding(keyCode: 0x23, modifiers: CarbonModifier.control | CarbonModifier.option)

/// ANSI klavyede tuş kodunun etiketi; bilinmeyen tuşta nil.
private let keyNames: [UInt32: String] = [
    0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
    0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
    0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
    0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
    0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x31: "Boşluk",
    0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
    0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
]

/// İşlev tuşları (F1–F12) değiştiricisiz de kullanılabilir.
private let functionKeyCodes: Set<UInt32> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]

/// Kısayolun okunur hali, ör. "⌃⌥R"; tuş bilinmiyorsa kodu. Saf fonksiyondur.
public func keyBindingDisplay(binding: KeyBinding) -> String {
    let symbols: [(mask: UInt32, symbol: String)] = [
        (CarbonModifier.control, "⌃"), (CarbonModifier.option, "⌥"), (CarbonModifier.shift, "⇧"), (CarbonModifier.command, "⌘"),
    ]
    let prefix: String = symbols.filter { binding.modifiers & $0.mask != 0 }.map(\.symbol).joined()
    let key: String = binding.keyCode == 0x31 ? String(localized: "Boşluk") : (keyNames[binding.keyCode] ?? "#\(binding.keyCode)")
    return prefix + key
}

/// Global kısayol olarak kullanılabilir mi: bilinen tuş ve (işlev tuşları dışında) en az bir ⌃/⌥/⌘;
/// yalnızca ⇧ ile yazı yazarken tetiklenirdi. Saf fonksiyondur.
public func isUsableGlobalBinding(binding: KeyBinding) -> Bool {
    guard keyNames[binding.keyCode] != nil else {
        return false
    }
    let strong: UInt32 = CarbonModifier.control | CarbonModifier.option | CarbonModifier.command
    return functionKeyCodes.contains(binding.keyCode) || binding.modifiers & strong != 0
}

/// Menüdeki kısayol ipucu için harf (küçük); harf/rakam olmayan tuşta nil. Saf fonksiyondur.
public func keyEquivalentCharacter(binding: KeyBinding) -> Character? {
    guard let name = keyNames[binding.keyCode], name.count == 1, let character = name.lowercased().first else {
        return nil
    }
    return character
}

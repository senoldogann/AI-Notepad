import Foundation
import Testing
@testable import AINotepadCore

@Suite struct ShortcutConflictTests {
    // Gerçek ölçüm: bu Mac'te Space + ⌃⌥ (0x1800) "sonraki giriş kaynağı" olarak etkin.
    let system: [SystemShortcut] = [
        SystemShortcut(keyCode: 49, modifiers: 0x1800, isEnabled: true),
        SystemShortcut(keyCode: 49, modifiers: 0x1200, isEnabled: false),
        SystemShortcut(keyCode: 15, modifiers: 0x21000, isEnabled: true),
    ]

    @Test func enabledSystemShortcutIsTaken() {
        #expect(isTakenBySystem(keyCode: 49, modifiers: 0x1800, systemShortcuts: system))
    }

    @Test func disabledOrDifferentShortcutIsFree() {
        #expect(!isTakenBySystem(keyCode: 49, modifiers: 0x1200, systemShortcuts: system))
        #expect(!isTakenBySystem(keyCode: 35, modifiers: 0x1800, systemShortcuts: system))
        // Yalnızca ⌃ (+ ilgisiz bit) olan R kısayolu ⌃⌥R ile çakışmaz.
        #expect(!isTakenBySystem(keyCode: 15, modifiers: 0x1800, systemShortcuts: system))
    }
}

import SwiftUI

/// Menü çubuğunda çalışan uygulamanın giriş noktası.
@main
struct AINotepadApp: App {
    var body: some Scene {
        MenuBarExtra("AI-Notepad", systemImage: "waveform") {
            Button("Çık") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

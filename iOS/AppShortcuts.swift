import AppIntents

/// Kısayollar ve Siri'de hazır gelen komutlar.
struct AINotepadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["\(.applicationName) ile toplantıyı kaydet", "\(.applicationName) kaydı başlat"],
            shortTitle: "Toplantıyı kaydet",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["\(.applicationName) kaydı bitir"],
            shortTitle: "Kaydı bitir",
            systemImageName: "stop.fill"
        )
    }
}

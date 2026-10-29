#if DEBUG
import AINotepadCore
import AINotepadUI
import AppKit
import Darwin
import Foundation
import os

// Tanıtım modu (yalnız Debug): web sitesindeki ekran görüntüleri için uygulama sahte ama inandırıcı İngilizce verilerle
// açılır (`scripts/make-screenshots.sh`). Kullanıcının verisine dokunmamak için veri klasörü geçici bir eve
// yönlendirilmiş olmalıdır (`CFFIXED_USER_HOME`); değilse uygulama hiçbir şey yazmadan durur. Bu modda sunucuya
// bağlanılmaz, Anahtar Zinciri'nde yalnızca hiç kullanılmayan bir servis adı sorgulanır, konuşma modeli yüklenmez.

private let demoLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Demo")

/// `--tanitim <sahne>` başlatma argümanı: tanıtım modu açık mı.
let isDemoMode: Bool = CommandLine.arguments.contains("--tanitim")

/// Tanıtım modunun Anahtar Zinciri servis adı: hiçbir öğesi yoktur, sahibin anahtarları okunmaz.
let demoKeychainService: String = "GistsmithTanitim"

/// Tanıtım modunda açılacak ekran.
enum DemoScene: String {
    /// Ana sayfa.
    case home = "ana"
    /// "Product weekly" toplantısının notu (görevler önce).
    case note = "not"
    /// Sor: kaynaklı cevabı olan saklı sohbet.
    case ask = "sor"
    /// Kayıt sürerken canlı panel (canlı metin ve çeviri).
    case live = "canli"
    /// Ana sayfa ve abone olma teklifi (deneme notu hazır; yalnız abonelik sürümünde).
    case upsell = "abone"
    /// Ana sayfa ve sağ altta güncelleme kartı (sahte sürüm ve notlar).
    case update = "guncelleme"
    /// Ayarlar (sekme `--ayar` ile seçilir; görsel kontrol için).
    case settings = "ayarlar"
}

/// Tanıtım modu hataları.
enum DemoModeError: Error, CustomStringConvertible {
    /// `CFFIXED_USER_HOME` ayarlanmamış ya da kullanıcının gerçek evini gösteriyor.
    case homeNotRedirected(value: String?)
    /// Veri klasörü geçici evin dışında çıktı.
    case dataFolderOutsideHome(dataFolder: String, home: String)
    /// `--tanitim` argümanından sonra tanınan bir sahne yok.
    case unknownScene(value: String?)

    var description: String {
        switch self {
        case .homeNotRedirected(let value):
            "Tanıtım modu yalnızca CFFIXED_USER_HOME geçici bir klasörü gösterirken açılır (gelen: \(value ?? "yok")); scripts/make-screenshots.sh kullan."
        case .dataFolderOutsideHome(let dataFolder, let home):
            "Tanıtım modu: veri klasörü (\(dataFolder)) geçici evin (\(home)) dışında; kullanıcının verisine yazılmaz."
        case .unknownScene(let value):
            "Tanıtım modu: sahne tanınmadı (gelen: \(value ?? "yok")); ana, not, sor, canli ya da abone olmalı."
        }
    }
}

/// `--tanitim <sahne>` argümanından sahne. Saf fonksiyondur.
func demoScene(arguments: [String]) throws -> DemoScene {
    guard let index = arguments.firstIndex(of: "--tanitim"), arguments.indices.contains(index + 1) else {
        throw DemoModeError.unknownScene(value: nil)
    }
    guard let scene = DemoScene(rawValue: arguments[index + 1]) else {
        throw DemoModeError.unknownScene(value: arguments[index + 1])
    }
    return scene
}

/// Kullanıcının gerçek ev klasörü (ortam değişkenlerinden bağımsız, kullanıcı veritabanından).
private func realHomeDirectory() -> String? {
    guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
        return nil
    }
    return String(cString: directory)
}

/// Veri klasörünün geçici eve yönlendirildiğini doğrular; değilse hata fırlatır (hiçbir şey yazılmaz).
private func requireRedirectedDataFolder() throws -> URL {
    let fixedHome: String? = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]
    guard let home = fixedHome, !home.isEmpty, home.hasPrefix("/"),
          URL(filePath: home).standardizedFileURL.path != realHomeDirectory().map({ URL(filePath: $0).standardizedFileURL.path }) else {
        throw DemoModeError.homeNotRedirected(value: fixedHome)
    }
    let homePath: String = URL(filePath: home, directoryHint: .isDirectory).standardizedFileURL.path
    let dataFolder: URL = try AppPaths.applicationSupport()
    guard dataFolder.standardizedFileURL.path.hasPrefix(homePath + "/") else {
        throw DemoModeError.dataFolderOutsideHome(dataFolder: dataFolder.path, home: homePath)
    }
    return dataFolder
}

/// Tanıtım verisini (toplantılar, kişiler, Sor sohbeti) geçici veri klasörüne yazar; klasör yönlendirilmemişse hata.
func seedDemoData(now: Date) throws {
    _ = try requireRedirectedDataFolder()
    let sessions: URL = try AppPaths.sessionsDirectory()
    for record in demoMeetings(now: now) {
        let folder: URL = sessions.appending(path: record.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try saveMeeting(record: record, directory: folder)
    }
    try savePeopleBook(book: demoPeopleBook(now: now), url: try peopleFileURL())
    try saveAskConversation(conversation: demoAskConversation(now: now), directory: try AppPaths.askHistoryDirectory())
}

// MARK: Sahneler

/// Açılıştan sonra sahneyi kurar: bölümü seçer, Sor sohbetini açar ya da sahte bir kaydı canlı panelde gösterir.
@MainActor
func showDemoScene(scene: DemoScene, model: AppModel, router: MainWindowRouter, panel: LivePanelController, updater: AppUpdater, now: Date) {
    // Konuşma modeli yüklenmez (indirme yok); kayıt düğmeleri hazır görünür.
    model.modelStatus = .ready
    switch scene {
    case .home:
        router.section = .home
    case .note:
        router.section = .meetings
        router.selectedMeetingID = demoMeetingID(startedAt: productWeeklyStart(now: now))
    case .ask:
        router.section = .ask
        // Sohbetler arka planda okunur: okununca saklı sohbet açılır.
        Task {
            for _ in 0..<40 where model.askConversations.isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            model.openConversation(id: demoAskConversationID)
        }
    case .settings:
        router.section = .settings
    case .update:
        router.section = .home
        updater.showUpdateForDemo(update: AvailableAppUpdate(
            version: "0.1.6",
            releaseNotes: """
            Smoother playback and a lighter app.

            ## What's new
            - **Smooth playback.** The time and the highlighted word now move without stutter.
            - **Lighter while recording.** Gistsmith uses far less CPU during meetings.
            - **Subscribe in one step.** A short window takes you straight to checkout.
            - **Your avatar.** Your photo or your own colour orb next to Settings.
            - **Faster updates.** New versions reach you within minutes.
            """,
            releaseNotesURL: URL(string: "https://gistsmith.com"),
            isReadyToInstall: true
        ))
    case .upsell:
        router.section = .home
        #if HOSTED_EDITION
        HostedAccount.shared.showUpsellForDemo(moment: .trialNoteReady)
        #endif
    case .live:
        router.section = .home
        router.isRecordingFocusDismissed = true
        let live: (segments: [LiveSegment], translations: [SegmentID: String]) = demoLiveTranscript()
        model.transcript = live.segments
        model.translations = live.translations
        model.displayMode = .bilingual
        model.lockedLanguage = .finnish
        model.micOpenedForRecording = true
        model.recordingStartedAt = now.addingTimeInterval(-(23 * 60 + 14))
        model.isRecording = true
        model.audioLevels.showSample(values: [0.22, 0.48, 0.35, 0.71, 0.56, 0.88, 0.42, 0.66, 0.31, 0.58, 0.47, 0.79, 0.52, 0.63])
        panel.show(page: .live)
    }
    // Pencereler oluşturulduktan sonra Retina ekrana taşınır: görüntüler 2x çekilsin.
    Task {
        do {
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            return
        }
        // Sor sahnesi küçük pencerede: cevap pencereyi doldurur, sitedeki dar kartta okunur kalır.
        placeDemoWindows(mainSize: scene == .ask ? NSSize(width: 940, height: 600) : NSSize(width: 1200, height: 780))
    }
}

/// Ana pencereyi ve canlı paneli Retina (2x) ekranın ortasına taşır; ana pencere verilen boyuta getirilir. Retina ekran
/// yoksa uyarı loglanır ve pencereler yerinde kalır (görüntüler 1x olur).
@MainActor
private func placeDemoWindows(mainSize: NSSize) {
    guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) else {
        demoLogger.warning("Retina ekran yok; ekran görüntüleri 1x çekilecek")
        return
    }
    let visible: CGRect = screen.visibleFrame
    for window in NSApplication.shared.windows where window.isVisible {
        if window is KeyablePanel {
            let size: NSSize = NSSize(width: 420, height: 640)
            window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
            window.invalidateShadow()
        } else if window.styleMask.contains(.titled), window.level == .normal {
            let size: NSSize = NSSize(width: min(mainSize.width, visible.width - 40), height: min(mainSize.height, visible.height - 40))
            window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
    }
}

// MARK: Canlı kayıt

/// Canlı panelde gösterilen konuşma: Fince konuşan ekip, İngilizce çevirisi; "Sen" İngilizce.
func demoLiveTranscript() -> (segments: [LiveSegment], translations: [SegmentID: String]) {
    let lines: [(speaker: Speaker, person: Int?, start: Double, text: String, translation: String?, isFinal: Bool)] = [
        (.me, nil, 1295, "Great, so the export bug is the last blocker for the release candidate.", nil, true),
        (.others, 1, 1310, "Beta avataan siis neljästoista marraskuuta, eikö niin?", "So the beta opens on the fourteenth of November, right?", true),
        (.others, 1, 1316, "Tarvitsemme julkaisutiedotteen ennen sitä.", "We need the release notes before that.", true),
        (.me, nil, 1322, "Works for me. I'll write the release notes by Friday.", nil, true),
        (.others, 2, 1331, "Hyvä. Voitko lähettää hinnaston myös Ayşelle?", "Good. Could you also send Ayşe the pricing table?", true),
        (.others, 2, 1337, "Hän tarvitsee sen asiakastapaamiseen torstaina.", "She needs it for the customer meeting on Thursday.", true),
        (.me, nil, 1344, "Sure, I'll send it right after this call.", nil, true),
        (.others, 1, 1352, "Sitten vielä tukitiimi: sovitaan heidän kanssaan viikoittainen", "And one more thing, the support team: let's agree on a weekly", true),
        (.others, 1, 1358, "palaveri beetan ajaksi, vaikka keskiviikkoisin.", nil, false),
    ]
    var counters: [Speaker: Int] = [:]
    var segments: [LiveSegment] = []
    var translations: [SegmentID: String] = [:]
    for line in lines {
        let index: Int = counters[line.speaker] ?? 0
        counters[line.speaker] = index + 1
        let id: SegmentID = SegmentID(speaker: line.speaker, index: index)
        segments.append(LiveSegment(id: id, startSec: line.start, endSec: line.start + 5, text: line.text, isFinal: line.isFinal, failureMessage: nil, person: line.person))
        if let translation = line.translation {
            translations[id] = translation
        }
    }
    return (segments: segments, translations: translations)
}

// MARK: Toplantılar

/// Toplantının kimliği: oturum klasörünün adı (`yyyyMMdd-HHmmss`, yerel saat). Saf fonksiyondur.
func demoMeetingID(startedAt: Date) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: startedAt)
}

/// Bugünün verilen saati (yerel); saat henüz gelmediyse dünün aynı saati. Saf fonksiyondur.
private func todayAt(now: Date, hour: Int, minute: Int) -> Date {
    let calendar: Calendar = Calendar.current
    let start: Date = calendar.startOfDay(for: now)
    let candidate: Date = start.addingTimeInterval(Double(hour * 3600 + minute * 60))
    return candidate < now ? candidate : candidate.addingTimeInterval(-86_400)
}

/// `days` gün önceki verilen saat (yerel). Saf fonksiyondur.
private func daysAgo(now: Date, days: Int, hour: Int, minute: Int) -> Date {
    todayAt(now: now, hour: hour, minute: minute).addingTimeInterval(-Double(days) * 86_400)
}

/// "Product weekly"nin başlangıcı (bugün, sabah).
func productWeeklyStart(now: Date) -> Date {
    todayAt(now: now, hour: 9, minute: 30)
}

/// "Investor update"in başlangıcı (üç hafta önce).
private func investorUpdateStart(now: Date) -> Date {
    daysAgo(now: now, days: 22, hour: 16, minute: 0)
}

/// Bir toplantının yazılı satırı: konuşmacı (nil "Sen"), başlangıç saniyesi ve metin.
private struct DemoLine {
    let person: Int?
    let start: Double
    let text: String
}

/// Bir toplantının tanımı.
private struct DemoMeeting {
    let title: String
    let startedAt: Date
    let minutes: Int
    let folder: String
    let people: [Int: String]
    let attendees: [String]
    let lines: [DemoLine]
    let summary: String
    let decisions: [String]
    let tasks: [NoteTask]
    let glossary: [GlossaryEntry]
    let outline: [OutlineItem]
    /// Tamamlanmış görevlerin açıklamaları.
    let doneTasks: [String]
}

/// Tanımdan saklanan toplantıyı üretir. Saf fonksiyondur.
private func demoRecord(meeting: DemoMeeting) -> MeetingRecord {
    let segments: [StoredSegment] = meeting.lines.enumerated().map { (item: (offset: Int, element: DemoLine)) -> StoredSegment in
        let next: Double = item.offset + 1 < meeting.lines.count ? meeting.lines[item.offset + 1].start : item.element.start + 12
        return StoredSegment(
            key: "final-\(item.offset)", speaker: item.element.person == nil ? .me : .others, person: item.element.person,
            startSec: item.element.start, endSec: max(item.element.start + 2, next - 0.6), text: item.element.text, words: nil
        )
    }
    let note: MeetingNote = MeetingNote(title: meeting.title, summary: meeting.summary, decisions: meeting.decisions, tasks: meeting.tasks, glossary: meeting.glossary)
        .with(outline: meeting.outline)
        .with(language: .english)
    let done: [String] = meeting.tasks.filter { meeting.doneTasks.contains($0.description) }.map { taskKey(task: $0) }
    return MeetingRecord(
        id: demoMeetingID(startedAt: meeting.startedAt), title: meeting.title, startedAt: meeting.startedAt,
        endedAt: meeting.startedAt.addingTimeInterval(Double(meeting.minutes * 60)), language: .english, status: .done, failureMessage: nil,
        liveSegments: [], finalSegments: segments, translations: [:], speakerNames: meeting.people, note: note, audioDeleted: false,
        engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
    .with(folder: meeting.folder)
    .with(attendees: meeting.attendees)
    .with(completedTasks: done)
}

/// Görev kısaltması: kullanıcıya ("Sen") düşen görev.
private func mine(_ description: String, due: String?) -> NoteTask {
    NoteTask(owner: "Alex", description: description, dueDate: due, isMine: true)
}

/// Görev kısaltması: başkasına düşen görev.
private func theirs(_ owner: String, _ description: String, due: String?) -> NoteTask {
    NoteTask(owner: owner, description: description, dueDate: due, isMine: false)
}

/// Tanıtımın toplantıları (yeniden eskiye). Saf fonksiyondur.
func demoMeetings(now: Date) -> [MeetingRecord] {
    let meetings: [DemoMeeting] = [
        DemoMeeting(
            title: "Product weekly", startedAt: productWeeklyStart(now: now), minutes: 42, folder: "Product",
            people: [1: "Elif", 2: "Mikko", 3: "Ayşe"], attendees: ["Elif Kaya", "Mikko Virtanen", "Ayşe Demir"],
            lines: [
                DemoLine(person: 1, start: 4, text: "Morning, everyone. Three things today: the beta date, pricing, and how we support the first customers."),
                DemoLine(person: 1, start: 14, text: "Engineering says the release candidate is stable. I'd like to open the beta on the fourteenth of November."),
                DemoLine(person: 2, start: 25, text: "From our side that works. The export sync bug is the last blocker, and I'll have it fixed by Thursday."),
                DemoLine(person: nil, start: 37, text: "Works for me. I'll write the release notes by Friday so they're ready a week ahead."),
                DemoLine(person: 3, start: 48, text: "Sales has eighty customers who asked to join. Can we invite all of them in the first wave?"),
                DemoLine(person: 1, start: 59, text: "Let's cap the first wave at two hundred accounts in total and confirm the list on Monday."),
                DemoLine(person: 3, start: 612, text: "On pricing: I have the Nordia call on Thursday and I need the latest pricing table before then."),
                DemoLine(person: nil, start: 624, text: "I'll send you the pricing table today, right after this call."),
                DemoLine(person: 1, start: 636, text: "And we keep the current tiers for the beta. No discounts until we see the usage numbers."),
                DemoLine(person: 2, start: 1310, text: "One more thing: support should have a weekly sync with us while the beta runs."),
                DemoLine(person: nil, start: 1322, text: "Agreed. I'll set up a Wednesday call with the support team."),
                DemoLine(person: 1, start: 2390, text: "Great. Beta on the fourteenth, release notes Friday, pricing table today. Thanks, everyone."),
            ],
            summary: "The team agreed to open the beta on 14 November once the export sync bug is fixed. The first wave is capped at 200 accounts, including the 80 customers sales has lined up; the list is confirmed on Monday. Pricing stays on the current tiers during the beta, and support gets a weekly sync with product and engineering.",
            decisions: [
                "The beta opens on 14 November.",
                "The first wave is capped at 200 accounts.",
                "Pricing stays on the current tiers during the beta.",
                "Support gets a weekly sync while the beta runs.",
            ],
            tasks: [
                mine("Write the beta release notes", due: "Friday"),
                mine("Send Ayşe the latest pricing table", due: "Today"),
                mine("Set up a weekly Wednesday call with support", due: "Wednesday"),
                theirs("Mikko", "Fix the export sync bug", due: "Thursday"),
                theirs("Elif", "Confirm the first-wave invite list with sales", due: "Monday"),
            ],
            glossary: [
                GlossaryEntry(term: "RC", meaning: "Release candidate: the build that becomes the beta if no blocker is found."),
                GlossaryEntry(term: "First wave", meaning: "The first 200 accounts invited to the beta."),
            ],
            outline: [
                OutlineItem(startSec: 4, title: "Beta date", summary: "The release candidate is stable; the beta opens on 14 November."),
                OutlineItem(startSec: 48, title: "Who gets invited", summary: "The first wave is capped at 200 accounts and confirmed on Monday."),
                OutlineItem(startSec: 612, title: "Pricing", summary: "Current tiers stay; Ayşe gets the pricing table before the Nordia call."),
                OutlineItem(startSec: 1310, title: "Support during the beta", summary: "A weekly Wednesday sync with the support team."),
            ],
            doneTasks: []
        ),
        DemoMeeting(
            title: "Client call · Nordia", startedAt: daysAgo(now: now, days: 1, hour: 14, minute: 0), minutes: 35, folder: "Clients",
            people: [1: "Jonas", 2: "Ayşe"], attendees: ["Jonas Berg", "Ayşe Demir"],
            lines: [
                DemoLine(person: 1, start: 6, text: "Thanks for making the time. Our team runs about forty meetings a week across Helsinki and Stockholm."),
                DemoLine(person: 1, start: 18, text: "Half of them are in Finnish or Swedish, so the translation is the main reason we're looking at this."),
                DemoLine(person: nil, start: 31, text: "That's exactly the use case. The live transcript runs on the Mac, and the note can be written in English."),
                DemoLine(person: 2, start: 44, text: "We can set up a two-week pilot for your leadership team."),
                DemoLine(person: 1, start: 57, text: "Good. Our security team will want to see where the audio goes before we start."),
                DemoLine(person: nil, start: 69, text: "I'll send the security overview and the data flow diagram tomorrow."),
            ],
            summary: "Nordia runs about 40 meetings a week across Helsinki and Stockholm, half of them in Finnish or Swedish; live translation is their main need. Both sides agreed on a two-week pilot for the leadership team, starting after Nordia's security review.",
            decisions: ["Two-week pilot for Nordia's leadership team.", "The pilot starts after Nordia's security review."],
            tasks: [
                mine("Send the security overview and data flow diagram", due: "Tomorrow"),
                theirs("Ayşe", "Draft the pilot agreement", due: "Next Tuesday"),
                theirs("Jonas", "Book the security review", due: "This week"),
            ],
            glossary: [GlossaryEntry(term: "Pilot", meaning: "A two-week trial with Nordia's leadership team.")],
            outline: [
                OutlineItem(startSec: 6, title: "Nordia's meetings", summary: "40 meetings a week, half in Finnish or Swedish."),
                OutlineItem(startSec: 44, title: "Pilot", summary: "Two weeks with the leadership team after a security review."),
            ],
            doneTasks: []
        ),
        DemoMeeting(
            title: "Design review", startedAt: daysAgo(now: now, days: 3, hour: 11, minute: 0), minutes: 50, folder: "Product",
            people: [1: "Elif", 2: "Lena"], attendees: ["Elif Kaya", "Lena Fischer"],
            lines: [
                DemoLine(person: 2, start: 5, text: "I simplified the onboarding to three screens: welcome, permissions, and sign in."),
                DemoLine(person: 1, start: 19, text: "Much better. Can the permission screen explain why we need the microphone?"),
                DemoLine(person: nil, start: 31, text: "Yes, one sentence each. And let's move tasks above the summary in the note."),
                DemoLine(person: 2, start: 44, text: "Agreed. I'll update the note layout and the empty states."),
            ],
            summary: "Lena presented a three-screen onboarding. The team agreed to explain each permission in one sentence and to show tasks above the summary in every note.",
            decisions: ["Onboarding has three screens.", "Tasks appear above the summary in every note."],
            tasks: [
                mine("Write one-sentence copy for each permission", due: "Thursday"),
                mine("Review the new empty states", due: nil),
                theirs("Lena", "Update the note layout so tasks come first", due: "Friday"),
                theirs("Lena", "Redesign the empty states", due: "Next week"),
                theirs("Elif", "Share the onboarding with five beta users", due: "Next week"),
            ],
            glossary: [],
            outline: [OutlineItem(startSec: 5, title: "Onboarding", summary: "Three screens; each permission explained in one sentence.")],
            doneTasks: ["Review the new empty states"]
        ),
        DemoMeeting(
            title: "Hiring sync", startedAt: daysAgo(now: now, days: 4, hour: 15, minute: 30), minutes: 25, folder: "Company",
            people: [1: "Elif", 2: "Daniel"], attendees: ["Elif Kaya", "Daniel Okafor"],
            lines: [
                DemoLine(person: 2, start: 4, text: "We have three strong candidates for the iOS role. Two of them can start in January."),
                DemoLine(person: 1, start: 16, text: "Let's do final interviews next week and decide by the twentieth."),
                DemoLine(person: nil, start: 28, text: "I can take the technical interview for the first two."),
            ],
            summary: "Three strong candidates for the iOS role; final interviews next week and a decision by 20 November.",
            decisions: ["Decision on the iOS role by 20 November."],
            tasks: [mine("Run the technical interviews", due: "Next week"), theirs("Daniel", "Schedule the final interviews", due: "Monday")],
            glossary: [],
            outline: [OutlineItem(startSec: 4, title: "iOS role", summary: "Three candidates; final interviews next week.")],
            doneTasks: []
        ),
        DemoMeeting(
            title: "One-on-one: Elif", startedAt: daysAgo(now: now, days: 7, hour: 10, minute: 0), minutes: 30, folder: "Team",
            people: [1: "Elif"], attendees: ["Elif Kaya"],
            lines: [
                DemoLine(person: 1, start: 3, text: "How are you feeling about the launch workload?"),
                DemoLine(person: nil, start: 11, text: "Busy but fine. I'd like to own the release notes and the beta onboarding emails."),
                DemoLine(person: 1, start: 24, text: "Sounds good. Let's revisit the support rotation after the beta."),
            ],
            summary: "Alex takes ownership of the release notes and the beta onboarding emails. The support rotation will be revisited after the beta.",
            decisions: ["Alex owns the release notes and onboarding emails."],
            tasks: [mine("Draft the beta onboarding emails", due: "Next Friday"), theirs("Elif", "Propose a new support rotation", due: "After the beta")],
            glossary: [],
            outline: [OutlineItem(startSec: 3, title: "Launch workload", summary: "Alex owns release notes and onboarding emails.")],
            doneTasks: []
        ),
        DemoMeeting(
            title: "Roadmap planning", startedAt: daysAgo(now: now, days: 10, hour: 13, minute: 0), minutes: 55, folder: "Product",
            people: [1: "Elif", 2: "Mikko"], attendees: ["Elif Kaya", "Mikko Virtanen"],
            lines: [
                DemoLine(person: 1, start: 5, text: "For the first quarter, I'd focus on the iPhone app and team workspaces."),
                DemoLine(person: 2, start: 18, text: "Workspaces need sync first. That's about six weeks of work."),
                DemoLine(person: nil, start: 31, text: "Then iPhone first, workspaces after sync is in place."),
            ],
            summary: "The first quarter focuses on the iPhone app; team workspaces follow once sync is in place, about six weeks of work.",
            decisions: ["iPhone app first in Q1.", "Workspaces follow after sync."],
            tasks: [mine("Write the Q1 roadmap one-pager", due: "Done"), theirs("Mikko", "Estimate the sync work", due: "Next week")],
            glossary: [GlossaryEntry(term: "Workspaces", meaning: "Shared folders of meetings for a team.")],
            outline: [OutlineItem(startSec: 5, title: "Q1 focus", summary: "iPhone app first, then workspaces.")],
            doneTasks: ["Write the Q1 roadmap one-pager"]
        ),
        DemoMeeting(
            title: "Investor update", startedAt: investorUpdateStart(now: now), minutes: 45, folder: "Company",
            people: [1: "Maria", 2: "Elif"], attendees: ["Maria Santos", "Elif Kaya"],
            lines: [
                DemoLine(person: 1, start: 6, text: "Revenue grew eighteen percent this quarter. Where do you want to put the extra budget?"),
                DemoLine(person: nil, start: 19, text: "We'd move forty thousand euros from paid ads to customer research and the beta."),
                DemoLine(person: 2, start: 33, text: "And we keep hiring flat until the beta numbers are in."),
                DemoLine(person: 1, start: 46, text: "That's sensible. Send me the updated budget before the board meeting."),
            ],
            summary: "Revenue grew 18% this quarter. €40k of the marketing budget moves from paid ads to customer research and the beta; hiring stays flat until the beta results are in. Maria wants the updated budget before the board meeting.",
            decisions: ["€40k moves from paid ads to customer research and the beta.", "Hiring stays flat until the beta results are in."],
            tasks: [
                mine("Send Maria the updated budget", due: "Before the board meeting"),
                mine("Plan customer research interviews", due: "November"),
                theirs("Elif", "Prepare beta metrics for the board", due: "December"),
                theirs("Maria", "Share the board meeting agenda", due: "Next week"),
            ],
            glossary: [],
            outline: [OutlineItem(startSec: 6, title: "Budget", summary: "€40k from paid ads to research and the beta; hiring flat.")],
            doneTasks: ["Send Maria the updated budget"]
        ),
    ]
    return meetings.map { (meeting: DemoMeeting) -> MeetingRecord in demoRecord(meeting: meeting) }
}

// MARK: Kişiler ve Sor

/// Tanıtımın kişi defteri (rol ve e-postalar). Saf fonksiyondur.
func demoPeopleBook(now: Date) -> PeopleBook {
    let people: [(name: String, role: String, email: String)] = [
        ("Elif", "Head of Product", "elif@example.com"),
        ("Mikko", "Engineering lead", "mikko@example.com"),
        ("Ayşe", "Sales", "ayse@example.com"),
        ("Jonas", "COO, Nordia", "jonas@example.com"),
        ("Lena", "Product designer", "lena@example.com"),
    ]
    return people.reduce(PeopleBook.empty) { (book: PeopleBook, person: (name: String, role: String, email: String)) -> PeopleBook in
        addingPerson(book: book, person: SavedPerson(name: person.name, role: person.role, email: person.email, addedAt: now.addingTimeInterval(-30 * 86_400)))
    }
}

/// Saklı Sor sohbetinin kimliği (sahne bunu açar).
let demoAskConversationID: UUID = UUID(uuid: (0x6B, 0x1E, 0x7C, 0x52, 0x3A, 0x0F, 0x4C, 0x4B, 0x9E, 0x58, 0x2D, 0x6F, 0x3B, 0x1A, 0x9C, 0x10))

/// Bütçe sorusu ve kaynaklı cevabı (Investor update ve Product weekly). Saf fonksiyondur.
func demoAskConversation(now: Date) -> AskConversation {
    let investorStart: Date = investorUpdateStart(now: now)
    let weeklyStart: Date = productWeeklyStart(now: now)
    let sources: [ArchivePassage] = [
        ArchivePassage(
            id: "demo-1", meetingID: demoMeetingID(startedAt: investorStart), meetingTitle: "Investor update", meetingDate: investorStart, kind: .note, startSec: 0,
            text: "€40k of the marketing budget moves from paid ads to customer research and the beta; hiring stays flat until the beta results are in."
        ),
        ArchivePassage(
            id: "demo-2", meetingID: demoMeetingID(startedAt: investorStart), meetingTitle: "Investor update", meetingDate: investorStart, kind: .transcript, startSec: 19,
            text: "We'd move forty thousand euros from paid ads to customer research and the beta."
        ),
        ArchivePassage(
            id: "demo-3", meetingID: demoMeetingID(startedAt: weeklyStart), meetingTitle: "Product weekly", meetingDate: weeklyStart, kind: .note, startSec: 0,
            text: "Pricing stays on the current tiers during the beta. No discounts until we see the usage numbers."
        ),
    ]
    let question: String = "What did we decide about the budget?"
    let answer: String = """
    Two decisions shape the budget right now:

    - **€40k moves from paid ads to customer research and the beta.** You proposed it in the investor update and Maria agreed [1][2].
    - **Hiring stays flat** until the beta results are in [1].

    For the beta itself, pricing stays on the current tiers, with no discounts until the usage numbers are in [3]. Your open task is to send Maria the updated budget before the board meeting.
    """
    let askedAt: Date = now.addingTimeInterval(-25 * 60)
    let turn: AskConversationTurn = AskConversationTurn(
        id: UUID(uuid: (0x0C, 0x9B, 0x6E, 0x3D, 0x7F, 0x21, 0x4E, 0x8A, 0xA1, 0xD4, 0x5B, 0x3C, 0x2E, 0x9F, 0x8A, 0x71)), question: question, scopeMeetingIDs: [], scopeTitles: [], recipeTitle: nil,
        startedAt: askedAt, finishedAt: askedAt.addingTimeInterval(6), terms: ["budget", "paid ads", "hiring", "pricing"], readPassages: sources,
        answer: answer, sources: sources, modelName: nil
    )
    return askConversation(existing: nil, id: demoAskConversationID, turns: [turn], now: askedAt.addingTimeInterval(6))
}
#endif

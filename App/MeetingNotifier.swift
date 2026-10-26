import AINotepadCore
import CoreAudio
import Foundation
import UserNotifications

/// Bildirimlerin "Dinlemeye başla" eylemi ve kategorisi.
enum MeetingNotificationID {
    static let category: String = "meeting.start"
    static let startAction: String = "meeting.start.listen"
    static let reminderPrefix: String = "meeting.reminder."
    static let micSuggestion: String = "meeting.mic"
}

/// Bildirim izni reddedildi.
enum NotificationError: Error, Equatable {
    case denied
    case scheduleFailed(reason: String)
}

/// Toplantı bildirimleri (UserNotifications): başlamadan 1 dk önce hatırlatma ve görüşme başladı önerisi; ikisinde de
/// "Dinlemeye başla" düğmesi.
@MainActor
final class MeetingNotifier {
    private let center: UNUserNotificationCenter = UNUserNotificationCenter.current()

    init() {
        let start: UNNotificationAction = UNNotificationAction(identifier: MeetingNotificationID.startAction, title: String(localized: "Dinlemeye başla"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: MeetingNotificationID.category, actions: [start], intentIdentifiers: [])])
    }

    /// Bildirim izni ister.
    func requestAuthorization() async throws {
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
        guard granted else {
            throw NotificationError.denied
        }
    }

    /// Önceki toplantı hatırlatmalarını kaldırıp verilenler için başlangıçtan 1 dk önceye yenilerini kurar.
    func scheduleReminders(meetings: [CalendarMeeting]) async throws {
        let pending: [UNNotificationRequest] = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(MeetingNotificationID.reminderPrefix) })
        for meeting in meetings {
            let fire: Date = max(Date().addingTimeInterval(5), meeting.start.addingTimeInterval(-60))
            let content: UNMutableNotificationContent = UNMutableNotificationContent()
            content.title = String(localized: "1 dk sonra: \(meeting.title)")
            content.body = meeting.attendees.isEmpty
                ? String(localized: "Dinlemeye başlamak için tıkla.")
                : String(localized: "\(meeting.attendees.prefix(3).joined(separator: ", ")) · Dinlemeye başlamak için tıkla.")
            content.categoryIdentifier = MeetingNotificationID.category
            content.sound = .default
            let trigger: UNTimeIntervalNotificationTrigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.reminderPrefix + meeting.id, content: content, trigger: trigger))
            } catch {
                throw NotificationError.scheduleFailed(reason: error.localizedDescription)
            }
        }
    }

    /// Başka bir uygulama mikrofonu açtı: görüşme başlamış olabilir.
    func suggestRecording() async throws {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.title = String(localized: "Bir görüşme başlamış olabilir")
        content.body = String(localized: "Mikrofon başka bir uygulamada açıldı. Toplantıyı dinlemeye başlamak için tıkla.")
        content.categoryIdentifier = MeetingNotificationID.category
        do {
            try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.micSuggestion, content: content, trigger: nil))
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
    }
}

/// Varsayılan mikrofonun herhangi bir uygulamada kullanılıp kullanılmadığını (Core Audio) 5 sn'de bir denetler;
/// kullanılmıyorken kullanılmaya başlayınca `onStart` çağrılır.
@MainActor
final class MicrophoneActivityMonitor {
    private var task: Task<Void, Never>?

    func start(onStart: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            var wasRunning: Bool = defaultInputIsRunning()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                let running: Bool = defaultInputIsRunning()
                if running, !wasRunning {
                    onStart()
                }
                wasRunning = running
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Varsayılan giriş aygıtı herhangi bir süreçte çalışıyor mu; okunamazsa false.
private func defaultInputIsRunning() -> Bool {
    var device: AudioDeviceID = 0
    var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else {
        return false
    }
    var running: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else {
        return false
    }
    return running != 0
}

/// Bildirim izni hatasının kullanıcı metni. Saf fonksiyondur.
func notificationMessage(error: any Error) -> String {
    switch error {
    case NotificationError.denied:
        String(localized: "Bildirim izni yok: Sistem Ayarları › Bildirimler › AI-Notepad'den izin ver.")
    case NotificationError.scheduleFailed(let reason):
        String(localized: "Bildirim kurulamadı: \(reason)")
    default:
        userFacingMessage(error: error)
    }
}

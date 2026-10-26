import AINotepadCore
import EventKit
import Foundation

/// Takvim ve anımsatıcı erişimi reddedildi ya da kullanılamıyor.
enum EventKitError: Error, Equatable {
    case remindersAccessDenied
    case calendarAccessDenied
    case noReminderList
    case saveFailed(reason: String)
}

/// Apple Takvim ve Anımsatıcılar bağlantısı (EventKit). İzin ilk kullanımda sorulur; tek bir mağaza örneği paylaşılır.
@MainActor
final class EventKitConnector {
    private let store: EKEventStore = EKEventStore()

    /// Görevi varsayılan anımsatıcı listesine ekler (son gün çözülebildiyse tarihli).
    func addReminder(draft: ReminderDraft) async throws {
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            throw EventKitError.saveFailed(reason: error.localizedDescription)
        }
        guard granted else {
            throw EventKitError.remindersAccessDenied
        }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw EventKitError.noReminderList
        }
        let reminder: EKReminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = list
        reminder.dueDateComponents = draft.due
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw EventKitError.saveFailed(reason: error.localizedDescription)
        }
    }
}

/// EventKit hatasının kullanıcı metni. Saf fonksiyondur.
func eventKitMessage(error: any Error) -> String {
    switch error {
    case EventKitError.remindersAccessDenied:
        String(localized: "Anımsatıcılar'a erişim izni yok: Sistem Ayarları › Gizlilik ve Güvenlik › Anımsatıcılar'dan AI-Notepad'e izin ver.")
    case EventKitError.calendarAccessDenied:
        String(localized: "Takvime erişim izni yok: Sistem Ayarları › Gizlilik ve Güvenlik › Takvimler'den AI-Notepad'e izin ver.")
    case EventKitError.noReminderList:
        String(localized: "Anımsatıcılar'da liste yok: Anımsatıcılar uygulamasında bir liste oluştur.")
    case EventKitError.saveFailed(let reason):
        String(localized: "Anımsatıcı kaydedilemedi: \(reason)")
    default:
        userFacingMessage(error: error)
    }
}

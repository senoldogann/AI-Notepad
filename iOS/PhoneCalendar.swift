import AINotepadCore
import EventKit
import Foundation
import os

/// iPhone'da takvimin durumu.
enum PhoneCalendarState: Equatable {
    /// Ayar kapalı (varsayılan).
    case off
    case on
    /// Takvim izni yok ya da geri alındı: iPhone Ayarları'ndan verilmeli.
    case denied
    /// İzin istenemedi ya da takvim okunamadı; neden gösterilir.
    case failed(String)
}

/// iPhone takvimi (EventKit, Mac'teki bağlantıyla aynı): sıradaki toplantılar ve kayda bağlanacak süren toplantı. İzin
/// yalnızca kullanıcı Ayarlar'da takvimi açınca istenir.
@MainActor
@Observable
final class PhoneCalendar {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneCalendar")

    /// Şu andan (süren toplantılar dahil) 12 saat sonrasına kadarki etkinlikler.
    private(set) var meetings: [CalendarMeeting] = []
    private(set) var state: PhoneCalendarState = .off
    @ObservationIgnored private let eventKit: EventKitConnector = EventKitConnector()
    /// Takvim değişikliklerini izleyen görev (etkinlik eklendi, taşındı).
    @ObservationIgnored private var changesTask: Task<Void, Never>?

    /// Ayar açıksa takvimi okur ve değişiklikleri izler; izin sonradan geri alındıysa "izin yok" durumu. İzin sorulmaz.
    /// Açılışta ve uygulama öne gelince çağrılır.
    func start() {
        guard UserDefaults.standard.bool(forKey: PhoneSettingsKey.calendarEnabled) else {
            stopObserving()
            meetings = []
            state = .off
            return
        }
        guard eventKit.hasCalendarAccess else {
            stopObserving()
            meetings = []
            state = .denied
            return
        }
        refresh()
        observeChanges()
    }

    /// Kullanıcı takvimi açtı: izin istenir (ilk kez iOS sorar). Verilmezse ayar kapalı kalır ve neden görünür.
    func enable() async {
        do {
            try await eventKit.requestCalendarAccess()
            UserDefaults.standard.set(true, forKey: PhoneSettingsKey.calendarEnabled)
            start()
        } catch EventKitError.calendarAccessDenied {
            UserDefaults.standard.set(false, forKey: PhoneSettingsKey.calendarEnabled)
            meetings = []
            state = .denied
        } catch {
            Self.logger.error("Takvim izni istenemedi, hata: \(String(describing: error), privacy: .public)")
            UserDefaults.standard.set(false, forKey: PhoneSettingsKey.calendarEnabled)
            meetings = []
            state = .failed(eventKitMessage(error: error))
        }
    }

    /// Kullanıcı takvimi kapattı.
    func disable() {
        UserDefaults.standard.set(false, forKey: PhoneSettingsKey.calendarEnabled)
        stopObserving()
        meetings = []
        state = .off
    }

    /// Kayda bağlanacak toplantı: takvim açıksa şu an süren (10 dk erken başlama payıyla) etkinlik; yoksa nil. Takvim
    /// önce yeniden okunur (uygulama saatlerce açık kalmış olabilir).
    func meetingForRecording(now: Date) -> CalendarMeeting? {
        guard state == .on else {
            return nil
        }
        refresh()
        return currentMeeting(meetings: meetings, now: now)
    }

    /// Takvimi yeniden okur; okunamazsa neden durumda görünür.
    private func refresh() {
        do {
            meetings = try eventKit.meetings(from: Date(), hours: 12)
            state = .on
        } catch EventKitError.calendarAccessDenied {
            meetings = []
            state = .denied
        } catch {
            Self.logger.error("Takvim okunamadı, hata: \(String(describing: error), privacy: .public)")
            meetings = []
            state = .failed(eventKitMessage(error: error))
        }
    }

    private func observeChanges() {
        guard changesTask == nil else {
            return
        }
        let changes: NotificationCenter.Notifications = eventKit.changes
        changesTask = Task { [weak self] in
            for await _ in changes {
                self?.refresh()
            }
        }
    }

    private func stopObserving() {
        changesTask?.cancel()
        changesTask = nil
    }
}

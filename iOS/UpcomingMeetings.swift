import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kayıt ekranında sıradaki toplantılar (takvim açıksa, önümüzdeki 12 saat): saat, başlık, katılımcılar; görüşme
/// bağlantısı varsa "Katıl". Süren toplantı "Şimdi" ile işaretlenir: o sırada başlatılan kayıt onun adını alır. Takvim
/// izni yoksa kısa bir uyarı ve Ayarlar'a geçiş.
struct UpcomingCalendarSection: View {
    let calendar: PhoneCalendar
    let router: PhoneRouter

    var body: some View {
        switch calendar.state {
        case .on:
            // Saat ilerledikçe (dakikada bir) "Şimdi", vurgular ve biten toplantılar güncellenir; liste yalnız takvim
            // değişince çizilseydi eskirdi.
            TimelineView(.everyMinute) { (context: TimelineViewDefaultContext) in
                let now: Date = context.date
                let items: [CalendarMeeting] = upcomingMeetings(meetings: calendar.meetings, now: now, horizonSec: 12 * 3600)
                let current: CalendarMeeting? = currentMeeting(meetings: calendar.meetings, now: now)
                VStack(alignment: .leading, spacing: 10) {
                    PhoneSectionHeader(title: "Sıradaki toplantılar", actionTitle: nil, action: nil)
                    if items.isEmpty {
                        Text("Önümüzdeki 12 saatte takvimde toplantı yok.")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(items.prefix(4).enumerated()), id: \.element.id) { (item: (offset: Int, element: CalendarMeeting)) in
                                if item.offset > 0 {
                                    Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14)
                                }
                                UpcomingMeetingRow(meeting: item.element, isCurrent: item.element.id == current?.id, now: now)
                            }
                        }
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
                    }
                }
            }
        case .denied:
            Button {
                router.tab = .settings
            } label: {
                Label("Takvime erişim izni yok; sıradaki toplantılar görünmüyor. Ayarlar'a git.", systemImage: "calendar.badge.exclamationmark")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        case .failed(let message):
            PhoneErrorList(messages: [message])
        case .off:
            EmptyView()
        }
    }
}

/// Sıradaki toplantı satırı: saat aralığı (süren ya da 10 dk içinde başlayan vurgulu), başlık, katılımcılar ve "Katıl".
private struct UpcomingMeetingRow: View {
    let meeting: CalendarMeeting
    /// Şu an süren toplantı: yeni kayıt buna bağlanır.
    let isCurrent: Bool
    let now: Date
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let isSoon: Bool = isCurrent || meeting.start.timeIntervalSince(now) <= 600
        let format: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale())
        let time: String = meeting.start.formatted(format) + "–" + meeting.end.formatted(format)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isCurrent {
                        Text("Şimdi")
                            .appFont(size: 12, weight: .semibold)
                            .foregroundStyle(appearance.accent.color)
                    }
                    Text(verbatim: time)
                        .appFont(size: 12, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(isSoon ? appearance.accent.color : Theme.muted)
                }
                Text(meeting.title)
                    .appFont(size: 15, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if !meeting.attendees.isEmpty {
                    Text(verbatim: meeting.attendees.prefix(3).joined(separator: ", ") + (meeting.attendees.count > 3 ? " +\(meeting.attendees.count - 3)" : ""))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let url = meeting.joinURL {
                Link(destination: url) {
                    Text("Katıl")
                        .appFont(size: 13, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.soft, in: Capsule())
                }
                .accessibilityLabel(Text("Görüşmeye katıl: \(meeting.title)"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

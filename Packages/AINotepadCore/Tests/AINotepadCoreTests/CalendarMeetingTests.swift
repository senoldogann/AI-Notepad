import Foundation
import Testing
@testable import AINotepadCore

@Suite struct CalendarMeetingTests {
    private func meeting(_ id: String, startMin: Double, durationMin: Double) -> CalendarMeeting {
        let base: Date = Date(timeIntervalSince1970: 1_800_000_000)
        return CalendarMeeting(id: id, title: id, start: base.addingTimeInterval(startMin * 60), end: base.addingTimeInterval((startMin + durationMin) * 60), attendees: [], joinURL: nil)
    }

    // Görüşme bağlantısı ve katılımcı adları takvim alanlarından doğru çıkar.
    @Test func joinLinksAndAttendeeNames() {
        #expect(meetingJoinURL(texts: ["Neuvotteluhuone 2", "Liity: https://teams.microsoft.com/l/meetup-join/19%3a123 kiitos"])?.host == "teams.microsoft.com")
        #expect(meetingJoinURL(texts: ["https://us02web.zoom.us/j/8812345?pwd=abc"])?.absoluteString == "https://us02web.zoom.us/j/8812345?pwd=abc")
        #expect(meetingJoinURL(texts: ["https://example.com/agenda"]) == nil)
        #expect(attendeeName(raw: "aino.virtanen@yritys.fi") == "Aino Virtanen")
        #expect(attendeeName(raw: "\"Mikko Korhonen\" <mikko@yritys.fi>") == "Mikko Korhonen")
        #expect(attendeeName(raw: "Riikka") == "Riikka")
        #expect(attendeeName(raw: "1234@x.fi") == nil)
        #expect(keytermsWithAttendees(attendees: ["Aino", "Mikko"], keyterms: ["aino", "budjetti", "raportti"], limit: 3) == ["Aino", "Mikko", "budjetti"])
    }

    // Kayıt anındaki toplantı 10 dk erken başlamayı kapsar; tüm gün etkinlikleri sayılmaz; hatırlatılacaklar sıralı.
    @Test func currentAndUpcomingMeetings() {
        let base: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let meetings: [CalendarMeeting] = [meeting("koko-päivä", startMin: -60, durationMin: 24 * 60), meeting("palaveri", startMin: 8, durationMin: 30), meeting("myöhemmin", startMin: 120, durationMin: 30), meeting("ohi", startMin: -90, durationMin: 30)]
        #expect(currentMeeting(meetings: meetings, now: base)?.id == "palaveri")
        #expect(currentMeeting(meetings: meetings, now: base.addingTimeInterval(-600)) == nil)
        #expect(meetingsToRemind(meetings: meetings, now: base, horizonSec: 3 * 3600).map(\.id) == ["palaveri", "myöhemmin"])
        let briefing: String = briefingQuestion(meeting: CalendarMeeting(id: "x", title: "Budjetti", start: base, end: base, attendees: ["Aino", "Mikko"], joinURL: nil))
        #expect(briefing.contains("Budjetti") && briefing.contains("Aino, Mikko") && briefing.contains("açık"))
    }
}

import Foundation
import Testing
@testable import AINotepadCore

@Suite struct CalendarMeetingTests {
    private func meeting(_ id: String, startMin: Double, durationMin: Double) -> CalendarMeeting {
        let base: Date = Date(timeIntervalSince1970: 1_800_000_000)
        return CalendarMeeting(id: id, title: id, start: base.addingTimeInterval(startMin * 60), end: base.addingTimeInterval((startMin + durationMin) * 60), attendees: [], joinURL: nil)
    }

    // Etkinliğin kaydı: bağlı kimlikle, eski kayıtta aynı başlık ve zaman aralığıyla bulunur; başka etkinliğinki karışmaz.
    @Test func findsRecordOfCalendarEvent() {
        let event: CalendarMeeting = meeting("Viikkopalaveri", startMin: 0, durationMin: 30)
        let record: (String, Double) -> MeetingRecord = { (title: String, startMin: Double) -> MeetingRecord in
            MeetingRecord(
                id: "\(title)-\(startMin)", title: title, startedAt: event.start.addingTimeInterval(startMin * 60), endedAt: nil, language: nil,
                status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil,
                audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
            )
        }
        #expect(recordedMeeting(meeting: event, records: [record("Viikkopalaveri", 2), record("Muu", 1)])?.id == "Viikkopalaveri-2.0")
        #expect(recordedMeeting(meeting: event, records: [record("Viikkopalaveri", 45)]) == nil)
        let linked: MeetingRecord = record("Toplantı", 60).with(calendarEventID: event.id)
        #expect(recordedMeeting(meeting: event, records: [record("Viikkopalaveri", 2), linked])?.id == linked.id)
        // Kendiliğinden kayıt: yalnızca süren, bağlantılı ve kaydı olmayan görüşme.
        let online: CalendarMeeting = CalendarMeeting(id: event.id, title: event.title, start: event.start, end: event.end, attendees: [], joinURL: URL(string: "https://teams.microsoft.com/l/x"))
        let during: Date = event.start.addingTimeInterval(120)
        #expect(meetingToAutoRecord(meetings: [online], records: [], now: during)?.id == event.id)
        #expect(meetingToAutoRecord(meetings: [event], records: [], now: during) == nil)
        #expect(meetingToAutoRecord(meetings: [online], records: [linked], now: during) == nil)
        #expect(meetingToAutoRecord(meetings: [online], records: [], now: event.end.addingTimeInterval(60)) == nil)
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

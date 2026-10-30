import Foundation

/// Takvimden bir toplantı (EventKit etkinliğinden; bağımsız değer tipi).
public struct CalendarMeeting: Sendable, Equatable, Identifiable, Codable {
    /// Etkinlik kimliği (tekrarlayan etkinlikte başlangıçla birlikte tekildir).
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    /// Katılımcıların adları (e-posta adresleri ayıklanmış; kullanıcının kendisi hariç).
    public let attendees: [String]
    /// Görüşme bağlantısı (Teams, Zoom, Meet, Webex); yoksa nil.
    public let joinURL: URL?

    public init(id: String, title: String, start: Date, end: Date, attendees: [String], joinURL: URL?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.joinURL = joinURL
    }
}

/// Görüşme servislerinin alan adları; bağlantının ana bilgisayarı bunlardan biri ya da alt alan adı olmalı.
let meetingHosts: [String] = [
    "teams.microsoft.com", "teams.live.com", "zoom.us", "zoomgov.com", "meet.google.com", "webex.com", "gotomeeting.com", "meet.goto.com",
    "chime.aws", "whereby.com", "around.co",
]

/// Konum, not ve adres alanlarındaki ilk görüşme bağlantısı (Teams, Zoom, Google Meet, Webex). Yalnız ana bilgisayarı
/// servisin alan adı ya da alt alan adı olan `https` bağlantısı kabul edilir: `https://evil.example/?x=zoom.us` ya da
/// `https://zoom.us.evil.example/` gibi takvim davetine yazılmış sahte adresler açılmaz. Metne yapışık sondaki
/// noktalama ("(https://meet.google.com/abc)", "…/j/123.") bağlantıya katılmaz. Saf fonksiyondur.
public func meetingJoinURL(texts: [String]) -> URL? {
    let candidate: Regex = /https:\/\/[^\s<>"]+/
    for text in texts {
        for match in text.matches(of: candidate) {
            guard let url = URL(string: trimmingTrailingPunctuation(link: String(match.output))), url.scheme == "https", let host = url.host()?.lowercased(),
                  meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
                continue
            }
            return url
        }
    }
    return nil
}

/// Metindeki bağlantının sonuna yapışmış noktalama atılır: `.,;:!?'` her zaman, kapanan parantez (`)`, `]`, `}`)
/// yalnızca bağlantıda açılışından fazlaysa (bağlantının kendi parantezi kalır). Saf fonksiyondur.
func trimmingTrailingPunctuation(link: String) -> String {
    let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    var result: Substring = Substring(link)
    while let last = result.last {
        if ".,;:!?'".contains(last) {
            result = result.dropLast()
        } else if let opening = pairs[last], result.filter({ $0 == last }).count > result.filter({ $0 == opening }).count {
            result = result.dropLast()
        } else {
            break
        }
    }
    return String(result)
}

/// Katılımcı adı: EventKit adı e-posta ya da "Ad Soyad <e-posta>" olabilir; e-posta yerine adın kendisi, yalnız
/// e-postada "@" öncesi noktalarla ayrılmış ad ("aino.virtanen@…" → "Aino Virtanen"). Boşsa nil. Saf fonksiyondur.
public func attendeeName(raw: String) -> String? {
    let trimmed: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let bracket = trimmed.firstIndex(of: "<") {
        let name: String = trimmed[..<bracket].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        return name.isEmpty ? attendeeName(raw: String(trimmed[trimmed.index(after: bracket)...]).replacingOccurrences(of: ">", with: "")) : name
    }
    guard trimmed.contains("@") else {
        return trimmed.isEmpty ? nil : trimmed
    }
    let local: String = String(trimmed.split(separator: "@").first ?? "")
    let parts: [String] = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        .filter { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

/// Kayıt başlarken bağlanacak toplantı: şu anı (10 dk erken başlama payıyla) kapsayan, başlangıcı şimdiye en yakın
/// etkinlik; tüm gün süren ve 8 saatten uzun etkinlikler toplantı sayılmaz. Saf fonksiyondur.
public func currentMeeting(meetings: [CalendarMeeting], now: Date) -> CalendarMeeting? {
    meetings
        .filter { $0.end.timeIntervalSince($0.start) <= 8 * 3600 && $0.start.addingTimeInterval(-600) <= now && now < $0.end }
        .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
}

/// Sıradaki toplantılar: bitmemiş (süren dahil) ve `horizonSec` içinde başlayan etkinlikler, başlangıca göre sıralı.
/// Saf fonksiyondur.
public func upcomingMeetings(meetings: [CalendarMeeting], now: Date, horizonSec: Double) -> [CalendarMeeting] {
    meetings
        .filter { $0.end > now && $0.start.timeIntervalSince(now) < horizonSec }
        .sorted { $0.start < $1.start }
}

/// Hatırlatma zamanlanacak toplantılar: henüz başlamamış, `horizonSec` içinde başlayan, 8 saatten kısa; sıralı.
/// Saf fonksiyondur.
public func meetingsToRemind(meetings: [CalendarMeeting], now: Date, horizonSec: Double) -> [CalendarMeeting] {
    meetings
        .filter { $0.start > now && $0.start.timeIntervalSince(now) <= horizonSec && $0.end.timeIntervalSince($0.start) <= 8 * 3600 }
        .sorted { $0.start < $1.start }
}

/// Tanıma terimleri: toplantı katılımcılarının adları öne, sonra diğer terimler; tekrarsız, en fazla `limit`. Saf
/// fonksiyondur.
public func keytermsWithAttendees(attendees: [String], keyterms: [String], limit: Int) -> [String] {
    (attendees + keyterms).compactMap(sanitizedKeyterm).reduce(into: [String]()) { (result: inout [String], term: String) -> Void in
        if !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            result.append(term)
        }
    }
    .prefix(limit)
    .map { $0 }
}

/// Takvim etkinliğinin kaydı: etkinliğe bağlanarak başlamış kayıt, yoksa (eski kayıtlar) aynı başlıkla etkinliğin
/// 15 dk öncesiyle bitişi arasında başlamış kayıt; en yenisi. Saf fonksiyondur.
public func recordedMeeting(meeting: CalendarMeeting, records: [MeetingRecord]) -> MeetingRecord? {
    records.first { $0.calendarEventID == meeting.id }
        ?? records
            .filter { (record: MeetingRecord) -> Bool in
                record.calendarEventID == nil && record.title == meeting.title
                    && record.startedAt >= meeting.start.addingTimeInterval(-900) && record.startedAt <= meeting.end
            }
            .max { $0.startedAt < $1.startedAt }
}

/// Kendiliğinden kaydedilecek toplantı: şu an süren (10 dk önceden itibaren), görüşme bağlantısı olan (çevrim içi
/// görüşme) ve henüz kaydı olmayan takvim toplantısı; yoksa nil. Saf fonksiyondur.
public func meetingToAutoRecord(meetings: [CalendarMeeting], records: [MeetingRecord], now: Date) -> CalendarMeeting? {
    currentMeeting(meetings: meetings.filter { $0.joinURL != nil }, now: now)
        .flatMap { recordedMeeting(meeting: $0, records: records) == nil ? $0 : nil }
}

/// Kullanıcının tanıma sözlüğü: satır ya da virgülle ayrılmış; servis kurallarına uymayanlar (2–40 karakter, en fazla
/// 5 sözcük) atılır. Saf fonksiyondur.
public func customVocabulary(text: String) -> [String] {
    text.split(whereSeparator: { $0 == "\n" || $0 == "," })
        .compactMap { sanitizedKeyterm(String($0)) }
}

/// Toplantı öncesi brifing sorusu (arşive sorulur): aynı kişilerle ya da konuda önceki görüşmeler, kararlar ve açık
/// görevler. Saf fonksiyondur.
public func briefingQuestion(meeting: CalendarMeeting) -> String {
    // Soru arayüz dilinde (İngilizce arayüzde İngilizce sorulur ve cevaplanır).
    guard !meeting.attendees.isEmpty else {
        return String(localized: "\"\(meeting.title)\" toplantısı öncesi brifing: Bu konuda önceki toplantılarda neler konuşuldu, hangi kararlar alındı, hangi görevler hâlâ açık? Kısa maddelerle, en yeniden başlayarak.")
    }
    let people: String = meeting.attendees.prefix(8).joined(separator: ", ")
    return String(localized: "\"\(meeting.title)\" toplantısı öncesi brifing. Katılımcılar: \(people). Bu kişilerle ya da bu konuda önceki toplantılarda neler konuşuldu, hangi kararlar alındı, hangi görevler hâlâ açık? Kısa maddelerle, en yeniden başlayarak.")
}

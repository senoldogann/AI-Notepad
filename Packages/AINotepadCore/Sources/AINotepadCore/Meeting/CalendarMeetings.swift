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

/// Konum, not ve adres alanlarındaki ilk görüşme bağlantısı (Teams, Zoom, Google Meet, Webex). Saf fonksiyondur.
public func meetingJoinURL(texts: [String]) -> URL? {
    let pattern: Regex = /https:\/\/[^\s<>"]*(teams\.microsoft\.com|teams\.live\.com|zoom\.us|meet\.google\.com|webex\.com)[^\s<>"]*/
    for text in texts {
        if let match = text.firstMatch(of: pattern), let url = URL(string: String(match.output.0)) {
            return url
        }
    }
    return nil
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
    (attendees + keyterms).reduce(into: [String]()) { (result: inout [String], term: String) -> Void in
        if !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            result.append(term)
        }
    }
    .prefix(limit)
    .map { $0 }
}

/// Toplantı öncesi brifing sorusu (arşive sorulur): aynı kişilerle ya da konuda önceki görüşmeler, kararlar ve açık
/// görevler. Saf fonksiyondur.
public func briefingQuestion(meeting: CalendarMeeting) -> String {
    let people: String = meeting.attendees.isEmpty ? "" : " Katılımcılar: \(meeting.attendees.prefix(8).joined(separator: ", "))."
    return "\"\(meeting.title)\" toplantısı öncesi brifing:\(people) Bu kişilerle ya da bu konuda önceki toplantılarda neler konuşuldu, hangi kararlar alındı, hangi görevler hâlâ açık? Kısa maddelerle, en yeniden başlayarak."
}

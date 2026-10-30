import Foundation

/// Toplantı listesinin tarih grubu.
public struct MeetingSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let meetings: [MeetingRecord]

    public init(id: String, title: String, meetings: [MeetingRecord]) {
        self.id = id
        self.title = title
        self.meetings = meetings
    }
}

/// Toplantıları tarihe göre gruplar (en yeni önce): Bugün, Dün, Önceki 7 gün (2–6 gün önce; takvim haftasına bağlı
/// değil), sonra ay ve yıl. Mac listesi ve iPhone kartları aynı grupları gösterir. Saf fonksiyondur.
public func meetingSections(records: [MeetingRecord], now: Date, calendar: Calendar, locale: Locale) -> [MeetingSection] {
    let today: Date = calendar.startOfDay(for: now)
    let title: (MeetingRecord) -> String = { (record: MeetingRecord) -> String in
        let day: Date = calendar.startOfDay(for: record.startedAt)
        let days: Int = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ..<1: return String(localized: "Bugün")
        case 1: return String(localized: "Dün")
        case 2..<7: return String(localized: "Önceki 7 gün")
        default: return record.startedAt.formatted(Date.FormatStyle().month(.wide).year().locale(locale)).capitalized(with: locale)
        }
    }
    return records.reduce(into: [MeetingSection]()) { (sections: inout [MeetingSection], record: MeetingRecord) -> Void in
        let name: String = title(record)
        if let last = sections.last, last.title == name {
            sections[sections.count - 1] = MeetingSection(id: last.id, title: last.title, meetings: last.meetings + [record])
        } else {
            sections.append(MeetingSection(id: name, title: name, meetings: [record]))
        }
    }
}

/// Mac toplantı listesinin süzgeci.
public enum MeetingListFilter: String, Sendable, CaseIterable {
    case all
    /// Notunda sana düşen görev olanlar.
    case myTasks
    /// Hata veren ya da yarıda kalan (yeniden işlenmesi gereken) toplantılar.
    case problems
}

/// Süzgece uyan toplantılar, sıra korunur. Saf fonksiyondur.
public func filterMeetings(records: [MeetingRecord], listFilter: MeetingListFilter) -> [MeetingRecord] {
    switch listFilter {
    case .all:
        records
    case .myTasks:
        records.filter { (record: MeetingRecord) -> Bool in record.note?.tasks.contains(where: \.isMine) ?? false }
    case .problems:
        records.filter { (record: MeetingRecord) -> Bool in record.status == .failed || record.status == .interrupted }
    }
}

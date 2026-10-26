import Foundation

/// Bir klasör ve içindeki toplantı sayısı.
public struct FolderSummary: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int

    public var id: String { name }
}

/// Klasörler: toplantılarda kullanılanlar ve kullanıcının oluşturduğu (henüz boş) klasörler; ada göre sıralı, aynı ad
/// (büyük/küçük harf duyarsız) bir kez. Saf fonksiyondur.
public func meetingFolders(records: [MeetingRecord], saved: [String]) -> [FolderSummary] {
    let used: [String] = records.compactMap(\.folder)
    let names: [String] = (saved + used).reduce(into: [String]()) { (result: inout [String], name: String) -> Void in
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            result.append(trimmed)
        }
    }
    return names
        .map { (name: String) -> FolderSummary in
            FolderSummary(name: name, count: used.filter { $0.caseInsensitiveCompare(name) == .orderedSame }.count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// Klasördeki toplantılar; klasör nil ise hepsi. Saf fonksiyondur.
public func meetingsInFolder(records: [MeetingRecord], folder: String?) -> [MeetingRecord] {
    guard let folder else {
        return records
    }
    return records.filter { $0.folder?.caseInsensitiveCompare(folder) == .orderedSame }
}

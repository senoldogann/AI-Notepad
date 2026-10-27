import Foundation

/// Dışa aktarılacak dosyanın yolu: `<klasör>/<başlık> <yyyy-MM-dd>.<uzantı>`; dosya adında kullanılamayan
/// karakterler atılır, aynı ad varsa " 2", " 3"… eklenir. Saf fonksiyondur (diskte yalnızca varlık sorulur).
public func exportFileURL(directory: URL, title: String, startedAt: Date, fileExtension: String) -> URL {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let cleaned: String = title
        .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let base: String = "\(cleaned.isEmpty ? String(localized: "Toplantı") : cleaned) \(formatter.string(from: startedAt))"
    let candidates: [URL] = [directory.appending(path: "\(base).\(fileExtension)")]
        + (2...999).map { directory.appending(path: "\(base) \($0).\(fileExtension)") }
    return candidates.first { !FileManager.default.fileExists(atPath: $0.path) } ?? candidates[candidates.count - 1]
}

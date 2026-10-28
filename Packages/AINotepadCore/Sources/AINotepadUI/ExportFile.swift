import Foundation

/// Dışa aktarılacak dosya için boş ad bulunamadı: `<ad>`, `<ad> 2` … `<ad> 999` klasörde zaten var.
public enum ExportFileError: Error, Equatable {
    case allNamesTaken(directory: String, baseName: String)
}

/// Dışa aktarılacak dosyanın yolu: `<klasör>/<başlık> <yyyy-MM-dd>.<uzantı>`; dosya adında kullanılamayan
/// karakterler atılır, aynı ad varsa " 2", " 3"… eklenir. Diskte adların varlığına bakar (saf değildir); hepsi
/// doluysa var olan dosyanın üzerine yazmak yerine hata verir.
public func exportFileURL(directory: URL, title: String, startedAt: Date, fileExtension: String) throws(ExportFileError) -> URL {
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
    guard let free = candidates.first(where: { (candidate: URL) -> Bool in !FileManager.default.fileExists(atPath: candidate.path) }) else {
        throw ExportFileError.allNamesTaken(directory: directory.path, baseName: base)
    }
    return free
}

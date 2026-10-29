import Foundation

/// Sürüm notlarının maddeleri: Markdown'da `- ` ya da `* ` ile başlayan satırlar (yeni özellikler ve düzeltmeler),
/// sırayla, en çok `limit` tane; madde işareti atılır, satır içi Markdown (kalın başlık) korunur. Güncelleme kartında
/// yenilikleri madde madde göstermek için. Saf fonksiyondur.
public func releaseNoteBullets(markdown: String, limit: Int) -> [String] {
    let bullets: [String] = markdown
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { (line: Substring) -> String in line.trimmingCharacters(in: .whitespaces) }
        .filter { (line: String) -> Bool in line.hasPrefix("- ") || line.hasPrefix("* ") }
        .map { (line: String) -> String in String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return Array(bullets.prefix(limit))
}

import Foundation

/// Transkriptin düz metni: her paragraf `[mm:ss] Ad: metin`, aralarında boş satır. Adlar toplantı sayfasındakiyle
/// aynıdır (`paragraphLabel`); transkript yoksa boş metin. Saf fonksiyondur.
public func transcriptText(record: MeetingRecord) -> String {
    transcriptParagraphs(record: record)
        .map { (paragraph: TranscriptParagraph) -> String in
            "[\(timestamp(seconds: paragraph.startSec))] \(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames)): \(singleLine(text: paragraph.text))"
        }
        .joined(separator: "\n\n")
}

/// Transkriptin SRT altyazısı: her paragraf numaralı bir ipucu (`HH:MM:SS,mmm --> HH:MM:SS,mmm`), metnin başında
/// konuşmacının adı. Transkript yoksa boş metin. Saf fonksiyondur.
public func transcriptSRT(record: MeetingRecord) -> String {
    transcriptParagraphs(record: record)
        .enumerated()
        .map { (item: (offset: Int, element: TranscriptParagraph)) -> String in
            let paragraph: TranscriptParagraph = item.element
            let start: String = srtTimestamp(seconds: paragraph.startSec)
            let end: String = srtTimestamp(seconds: max(paragraph.startSec, paragraph.endSec))
            let label: String = paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames)
            return "\(item.offset + 1)\n\(start) --> \(end)\n\(label): \(singleLine(text: paragraph.text))\n"
        }
        .joined(separator: "\n")
}

/// SRT zamanı: `HH:MM:SS,mmm` (milisaniyeye yuvarlanır, eksi süre sıfır sayılır). Saf fonksiyondur.
public func srtTimestamp(seconds: Double) -> String {
    let totalMilliseconds: Int = max(0, Int((seconds * 1000).rounded()))
    let hours: Int = totalMilliseconds / 3_600_000
    let minutes: Int = (totalMilliseconds % 3_600_000) / 60_000
    let secs: Int = (totalMilliseconds % 60_000) / 1000
    let milliseconds: Int = totalMilliseconds % 1000
    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
}

/// Satır sonlarını boşluğa çevirir: SRT'de boş satır ipucunu bitirir, düz metinde paragraf satırı bölünmesin.
private func singleLine(text: String) -> String {
    text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
}

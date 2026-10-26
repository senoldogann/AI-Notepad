import Foundation
import os

private let processLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ProcessMeeting")

/// Toplantı sonrası işleme: (1) `.caf` → `.m4a`, (2) ElevenLabs ile kaydın tamamından son geçiş transkripti
/// (anahtar yoksa — WhisperKit motoru — atlanır), (3) Claude Opus ile Türkçe not. Bir adım başarısız olursa o ana
/// kadarki ilerleme korunur, durum `failed` olur; ses dosyaları kaldığı için yeniden işlenebilir.
public func processMeeting(
    record: MeetingRecord,
    directory: URL,
    elevenLabsKey: String?,
    anthropicKey: String?,
    languageMode: LanguageMode,
    userName: String
) async -> MeetingRecord {
    var current: MeetingRecord = record.with(status: .processing, failureMessage: nil)

    for name in ["me", "others"] {
        let caf: URL = directory.appending(path: "\(name).caf")
        guard FileManager.default.fileExists(atPath: caf.path) else {
            continue
        }
        do {
            try convertToM4A(source: caf, destination: directory.appending(path: "\(name).m4a"))
            try FileManager.default.removeItem(at: caf)
        } catch {
            return failed(record: current, step: "Ses dönüştürülemedi", error: error)
        }
    }

    let othersAudio: URL = directory.appending(path: "others.m4a")
    if let elevenLabsKey, FileManager.default.fileExists(atPath: othersAudio.path) {
        do {
            let result: DiarizationResult = try await diarizeFile(
                apiKey: elevenLabsKey, fileURL: othersAudio, mimeType: "audio/mp4", languageMode: languageMode, timeoutSec: 300
            )
            current = updated(
                record: current,
                finalSegments: finalSegments(words: result.words, gapSec: 1.5),
                language: current.language ?? result.languageCode.flatMap { meetingLanguage(elevenLabsCode: $0) },
                note: current.note
            )
        } catch {
            return failed(record: current, step: "Konuşmacı ayırma başarısız", error: error)
        }
    }

    // Son geçiş "Diğerleri"ni kapsar; "Sen" için canlı bölümler kullanılır.
    let noteSegments: [StoredSegment] = current.finalSegments.isEmpty
        ? current.liveSegments
        : current.finalSegments + current.liveSegments.filter { $0.speaker == .me }
    guard let request = meetingNoteRequest(segments: noteSegments, speakerNames: current.speakerNames, userName: userName) else {
        return current.with(status: .done, failureMessage: nil)
    }
    guard let anthropicKey else {
        return current.with(status: .failed, failureMessage: "Not oluşturulamadı: Anthropic anahtarı kayıtlı değil. Ayarlar'dan ekleyip \"Tekrar işle\".")
    }
    do {
        let note: MeetingNote = try parseMeetingNote(text: try await sendClaude(apiKey: anthropicKey, request: request))
        return updated(record: current, finalSegments: current.finalSegments, language: current.language, note: note)
            .with(status: .done, failureMessage: nil)
    } catch {
        return failed(record: current, step: "Not oluşturulamadı", error: error)
    }
}

private func failed(record: MeetingRecord, step: String, error: any Error) -> MeetingRecord {
    processLogger.error("Toplantı işleme adımı başarısız: \(step, privacy: .public), hata: \(String(describing: error), privacy: .public)")
    return record.with(status: .failed, failureMessage: "\(step): \(error.localizedDescription)")
}

/// Son geçiş, dil ve not güncellenmiş kopya; not varsa başlık nottan gelir.
private func updated(record: MeetingRecord, finalSegments: [StoredSegment], language: MeetingLanguage?, note: MeetingNote?) -> MeetingRecord {
    MeetingRecord(
        id: record.id, title: note?.title ?? record.title, startedAt: record.startedAt, endedAt: record.endedAt,
        language: language, status: record.status, failureMessage: record.failureMessage,
        liveSegments: record.liveSegments, finalSegments: finalSegments, translations: record.translations,
        speakerNames: record.speakerNames, note: note, audioDeleted: record.audioDeleted
    )
}

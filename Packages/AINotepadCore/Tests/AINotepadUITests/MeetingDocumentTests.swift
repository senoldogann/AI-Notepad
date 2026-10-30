import AINotepadCore
import Foundation
import PDFKit
import Testing
@testable import AINotepadUI

private func sampleRecord(paragraphCount: Int) -> MeetingRecord {
    MeetingRecord(
        id: "20261026-100000", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        endedAt: Date(timeIntervalSince1970: 1_800_002_520), language: .finnish, status: .done, failureMessage: nil,
        liveSegments: [],
        finalSegments: (0..<paragraphCount).map { (index: Int) -> StoredSegment in
            StoredSegment(key: "final-\(index)", speaker: .others, person: index % 2 + 1, startSec: Double(index * 10), endSec: Double(index * 10 + 8),
                          text: "Seuraavalla viikolla meidän pitää palauttaa raportti ja sopia esityksestä numero \(index).", words: nil)
        },
        translations: ["final-0": "Gelecek hafta raporu teslim etmeliyiz."],
        speakerNames: [1: "Aino"],
        note: MeetingNote(
            title: "Rapor ve sunum", summary: "Rapor gelecek hafta teslim edilecek.", decisions: ["Sunum cuma."],
            tasks: [NoteTask(owner: "Doğan", description: "Slaytları hazırla", dueDate: "Perşembe", isMine: true),
                    NoteTask(owner: "Aino", description: "Raporu gönder", dueDate: nil, isMine: false)],
            glossary: [GlossaryEntry(term: "palauttaa", meaning: "teslim etmek")]
        ),
        audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct MeetingDocumentTests {
    // PDF çizimi AppKit ile: yalnızca macOS.
    #if os(macOS)
    @Test @MainActor func pdfHasNoteSectionsInOrderAndTranscript() throws {
        let document: PDFDocument = try #require(PDFDocument(data: try meetingPDF(record: sampleRecord(paragraphCount: 4))))
        let text: String = try #require(document.string)
        #expect(document.pageCount == 1)
        #expect(text.contains("Rapor ve sunum"))
        #expect(text.contains("Slaytları hazırla"))
        #expect(text.contains("Aino"))
        #expect(text.contains("Gelecek hafta raporu teslim etmeliyiz."))
        #expect(text.contains("Sayfa 1 / 1"))
        let mine: Range<String.Index> = try #require(text.range(of: "SENİN GÖREVLERİN"))
        let summary: Range<String.Index> = try #require(text.range(of: "ÖZET"))
        #expect(mine.lowerBound < summary.lowerBound)
    }

    // Uzun transkript sayfalara bölünür; metin kaybolmaz.
    @Test @MainActor func longTranscriptPaginates() throws {
        let document: PDFDocument = try #require(PDFDocument(data: try meetingPDF(record: sampleRecord(paragraphCount: 120))))
        #expect(document.pageCount > 3)
        let last: String = try #require(document.page(at: document.pageCount - 1)?.string)
        #expect(last.contains("Sayfa \(document.pageCount) / \(document.pageCount)"))
        #expect(try #require(document.string).contains("numero 119"))
    }

    // Word belgesi geri okununca not ve transkript metni yerinde.
    @Test func docxRoundTripsNoteAndTranscript() throws {
        let data: Data = try meetingDOCX(record: sampleRecord(paragraphCount: 4))
        let document: NSAttributedString = try NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil
        )
        #expect(document.string.contains("Rapor ve sunum"))
        #expect(document.string.contains("Slaytları hazırla"))
        #expect(document.string.contains("Gelecek hafta raporu teslim etmeliyiz."))
        #expect(document.string.contains("numero 3"))
    }

    /// Görsel kontrol için örnek PDF'i `AINOTEPAD_PDF_SAMPLE` yoluna yazar (yalnızca değişken verilirse).
    @Test @MainActor func writesSampleWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["AINOTEPAD_PDF_SAMPLE"] else {
            return
        }
        try meetingPDF(record: sampleRecord(paragraphCount: 30)).write(to: URL(fileURLWithPath: path))
    }

    #endif
    @Test func exportNameIsCleanAndUnique() throws {
        let directory: URL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first: URL = try exportFileURL(directory: directory, title: "Rapor / sunum: plan", startedAt: Date(timeIntervalSince1970: 1_800_000_000), fileExtension: "pdf")
        #expect(first.lastPathComponent == "Rapor  sunum plan 2027-01-15.pdf")
        try Data().write(to: first)
        #expect(try exportFileURL(directory: directory, title: "Rapor / sunum: plan", startedAt: Date(timeIntervalSince1970: 1_800_000_000), fileExtension: "pdf").lastPathComponent == "Rapor  sunum plan 2027-01-15 2.pdf")
        // Baştaki nokta atılır: gizli dosya olmaz.
        #expect(try exportFileURL(directory: directory, title: ".NET plan", startedAt: Date(timeIntervalSince1970: 1_800_000_000), fileExtension: "pdf").lastPathComponent == "NET plan 2027-01-15.pdf")
        try FileManager.default.removeItem(at: directory)
    }
}

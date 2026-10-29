import Foundation
import Testing
@testable import AINotepadCore

private let sampleNote: MeetingNote = MeetingNote(
    title: "Bütçe toplantısı",
    summary: "Aino gelecek yılın bütçesini sundu; pazarlama payı %10 artacak. Mikko raporun Cuma'ya hazır olacağını söyledi.",
    decisions: ["Pazarlama bütçesi %10 artırılacak."],
    tasks: [
        NoteTask(owner: "Senol", description: "Sunumun slaytlarını hazırlamak", dueDate: "Perşembe", isMine: true),
        NoteTask(owner: "Mikko", description: "Raporu göndermek", dueDate: "Cuma", isMine: false),
    ],
    glossary: [GlossaryEntry(term: "talousarvio", meaning: "bütçe")]
).with(outline: [
    OutlineItem(startSec: 12, title: "Gelecek yılın bütçesi", summary: "Aino bütçeyi sundu; pazarlama payı %10 artıyor."),
    OutlineItem(startSec: 95, title: "Rapor takvimi", summary: "Mikko raporun Cuma'ya hazır olacağını söyledi."),
])

private func sampleRecord() -> MeetingRecord {
    MeetingRecord(
        id: "1", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, language: .finnish,
        status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
        note: sampleNote, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct NoteTemplateTests {
    // Şablon yönergesi not istemine girer; genel şablonda ek yönerge yok; yeni not eski paylaşım sürümlerini siler.
    @Test func templateGoesIntoPromptAndNoteResetsShares() throws {
        let segments: [StoredSegment] = [stored("final-0", .others, 1, 0, "Budjetti on 10 000 euroa.")]
        let client: LLMRequest = try #require(meetingNoteRequest(segments: segments, speakerNames: [:], userName: "Senol", template: NoteTemplate(kind: .client, customInstructions: ""), myNotes: "", language: .turkish))
        #expect(client.system.contains("müşteri görüşmesi"))
        let custom: LLMRequest = try #require(meetingNoteRequest(segments: segments, speakerNames: [:], userName: "Senol", template: NoteTemplate(kind: .custom, customInstructions: "Riskleri ayrı say."), myNotes: "", language: .turkish))
        #expect(custom.system.contains("Riskleri ayrı say."))
        let general: LLMRequest = try #require(meetingNoteRequest(segments: segments, speakerNames: [:], userName: "Senol", template: .general, myNotes: "", language: .turkish))
        #expect(!general.system.contains("Toplantı türü"))
        let shared: MeetingRecord = sampleRecord().with(sharedNotes: ["fi": sampleNote])
        #expect(shared.with(note: sampleNote).sharedNotes == nil)
    }

    // Paylaşım metni notun dilindeki başlıklarla; Türkçede sözlük var, paylaşım dillerinde yok.
    @Test func shareTextUsesLanguageHeadings() {
        let finnish: String = shareText(record: sampleRecord(), note: sampleNote, language: .finnish)
        #expect(finnish.contains("## Yhteenveto") && finnish.contains("## Tehtävät") && !finnish.contains("talousarvio"))
        #expect(shareText(record: sampleRecord(), note: sampleNote, language: .japanese).contains("## 決定事項"))
        #expect(shareText(record: sampleRecord(), note: sampleNote, language: nil).contains("talousarvio"))
        // Çeviride görev sayısı değişirse kullanılmaz.
        #expect(throws: LLMError.self) {
            try parseSharedNote(text: #"{"baslik":"T","ozet":"S","kararlar":["a"],"gorevler":[],"sozluk":[]}"#, original: sampleNote)
        }
    }

    // Çeviri asıl notun tüm bölümlerini taşır: akış zamanları ve sözlük terimleri asıl nottan, metinler çeviriden; akışı
    // ya da sözlüğü eksik çeviri kullanılmaz; eski (akışsız, sözlüksüz) saklı çeviri eksik sayılır.
    @Test func sharedNoteKeepsOutlineAndGlossary() throws {
        let tasks: String = #"[{"sahip":"Senol","aciklama":"Prepare the slides","tarih":"Thursday","benimMi":true},{"sahip":"Mikko","aciklama":"Send the report","tarih":"Friday","benimMi":false}]"#
        let full: String = #"{"baslik":"Budget meeting","ozet":"Aino presented the budget.","kararlar":["Marketing budget up 10%."],"gorevler":"#
            + tasks
            + #","sozluk":[{"terim":"budget","anlam":"the yearly budget"}],"akis":[{"zaman":"00:13","baslik":"Next year's budget","ozet":"Aino presented it."},{"zaman":"01:30","baslik":"Report timing","ozet":"Report by Friday."}]}"#
        let shared: MeetingNote = try parseSharedNote(text: full, original: sampleNote)
        #expect(shared.outline?.map(\.startSec) == [12, 95])
        #expect(shared.outline?.map(\.title) == ["Next year's budget", "Report timing"])
        #expect(shared.glossary == [GlossaryEntry(term: "talousarvio", meaning: "the yearly budget")])
        #expect(isSharedNoteComplete(shared: shared, original: sampleNote))
        let withoutOutline: String = #"{"baslik":"B","ozet":"S","kararlar":["d"],"gorevler":"# + tasks + #","sozluk":[{"terim":"t","anlam":"m"}],"akis":[]}"#
        #expect(throws: LLMError.self) {
            try parseSharedNote(text: withoutOutline, original: sampleNote)
        }
        let old: MeetingNote = MeetingNote(title: "B", summary: "S", decisions: ["d"], tasks: sampleNote.tasks, glossary: [])
        #expect(!isSharedNoteComplete(shared: old, original: sampleNote))
    }
}

extension CloudTests {
@Suite struct SharedNoteCloudTests {
    // Gerçek model: not Fince, İngilizce ve farklı yazı sistemli dillere çevrilir; görev sayısı ve sahipliği korunur,
    // kullanıcı adıyla yazılır.
    @Test(arguments: [ShareLanguage.finnish, .english, .german, .japanese, .arabic])
    func noteTranslatesForSharing(language: ShareLanguage) async throws {
        let provider: LLMProvider = .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        let note: MeetingNote = try await requestStructured(provider: provider, request: sharedNoteRequest(note: sampleNote, language: language, userName: "Senol")) { (text: String) throws -> MeetingNote in
            try parseSharedNote(text: text, original: sampleNote)
        }
        #expect(note.tasks.map(\.isMine) == [true, false])
        #expect(note.tasks.first?.owner == "Senol")
        #expect(note.glossary.map(\.term) == ["talousarvio"])
        #expect(note.outline?.map(\.startSec) == [12, 95])
        let text: String = (note.summary + " " + note.tasks.map(\.description).joined(separator: " ")).lowercased()
        switch language {
        case .finnish:
            #expect(text.contains("aino") && ["markkinointi", "budjet", "rapor"].contains { text.contains($0) }, "\(text)")
        case .english:
            #expect(text.contains("aino") && ["marketing", "budget", "report"].contains { text.contains($0) }, "\(text)")
        case .german:
            #expect(text.contains("aino") && ["marketing", "budget", "bericht"].contains { text.contains($0) }, "\(text)")
        case .japanese:
            #expect(["予算", "マーケティング", "レポート", "報告"].contains { text.contains($0) }, "\(text)")
        case .arabic:
            #expect(["الميزانية", "التسويق", "التقرير"].contains { text.contains($0) }, "\(text)")
        default:
            Issue.record("beklenmeyen dil: \(language)")
        }
        #expect(!text.contains("bütçe") && !text.contains("rapor göndermek"), "çevrilmemiş: \(text)")
    }

    // Gerçek model: müşteri şablonu özette ihtiyaç/bütçe/sonraki adımları öne çıkarır.
    @Test func clientTemplateHighlightsBudgetAndNextSteps() async throws {
        let provider: LLMProvider = .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        let segments: [StoredSegment] = [
            stored("final-0", .others, 1, 0, "Tarvitsemme uuden asiakasportaalin ensi kevääksi, budjettimme on noin 40 000 euroa."),
            stored("me-0", .me, nil, 6, "Selvä. Lähetän teille tarjouksen ensi viikon tiistaina."),
            stored("final-1", .others, 1, 11, "Hyvä. Kilpailijanne Acme tarjosi jo, mutta heidän aikataulunsa oli liian hidas."),
        ]
        let note: MeetingNote = try #require(try await writeMeetingNote(segments: segments, speakerNames: [1: "Aino"], userName: "Senol", template: NoteTemplate(kind: .client, customInstructions: ""), myNotes: "", language: .turkish, llm: provider, progressFile: try temporaryDirectory().appending(path: "note-progress.json")))
        let summary: String = note.summary.lowercased()
        #expect(summary.contains("40") && summary.contains("acme"), "\(note.summary)")
        #expect(note.tasks.contains { $0.isMine }, "\(note.tasks)")
    }
}
}

import CryptoKit
import Foundation
import os

/// Bu kadar karaktere kadar transkript notu tek istekte yazılır; uzunu parçalara bölünür. Ölçüm (Haiku 5.5): ~23.000
/// karakterlik toplantıda tüm görevler çıktı, ~47.000'de model görevleri "her aşama için…" diye toplayıp çoğunu yazmadı.
/// Gerçek konuşma dakikada ~1.750 karakter: sınır ~12 dakikalık konuşmadır.
let noteChunkMaxChars: Int = 20_000

/// Uzun toplantının bir parçasından çıkanlar.
public struct NoteChunk: Sendable, Equatable {
    /// Bu parçanın kısa özeti (sonraki parçalara bağlam, son özete malzeme).
    public let summary: String
    public let decisions: [String]
    public let newTasks: [NoteTask]
    /// Önceki parçalardaki görevlerde değişiklik (numara 1'den başlar, bağlamdaki listeye göre).
    public let changedTasks: [TaskChange]
    public let glossary: [GlossaryEntry]

    public init(summary: String, decisions: [String], newTasks: [NoteTask], changedTasks: [TaskChange], glossary: [GlossaryEntry]) {
        self.summary = summary
        self.decisions = decisions
        self.newTasks = newTasks
        self.changedTasks = changedTasks
        self.glossary = glossary
    }
}

/// Daha önce çıkmış bir görevin sonraki parçada değişmesi (ör. tarih ertelendi) ya da iptali.
public struct TaskChange: Sendable, Equatable {
    /// Bağlamda verilen numaralı görev listesindeki numara (1'den başlar).
    public let number: Int
    public let description: String
    public let dueDate: String?
    public let isCancelled: Bool

    public init(number: Int, description: String, dueDate: String?, isCancelled: Bool) {
        self.number = number
        self.description = description
        self.dueDate = dueDate
        self.isCancelled = isCancelled
    }
}

/// Parçalar işlendikçe biriken not.
public struct ChunkedNoteState: Sendable, Equatable, Codable {
    /// Parça başına "[mm:ss–mm:ss] özet".
    public let partSummaries: [String]
    public let decisions: [String]
    public let tasks: [NoteTask]
    public let glossary: [GlossaryEntry]

    public init(partSummaries: [String], decisions: [String], tasks: [NoteTask], glossary: [GlossaryEntry]) {
        self.partSummaries = partSummaries
        self.decisions = decisions
        self.tasks = tasks
        self.glossary = glossary
    }

    public static let empty: ChunkedNoteState = ChunkedNoteState(partSummaries: [], decisions: [], tasks: [], glossary: [])
}

/// Bölümleri (zamana göre sıralı) en fazla `maxChars` metin karakterlik parçalara böler. Sınırın son %20'sinde
/// konuşmacı değişirse orada keser (cümle ve konuşma ortasından bölünmesin); tek bölüm sınırı aşsa da kendi parçasıdır.
/// Hiçbir bölüm atlanmaz, sıra korunur. Saf fonksiyondur.
public func noteChunks(segments: [StoredSegment], maxChars: Int) -> [[StoredSegment]] {
    var chunks: [[StoredSegment]] = []
    var current: [StoredSegment] = []
    var currentChars: Int = 0
    for segment in segments {
        let speakerChanged: Bool = current.last.map { $0.speaker != segment.speaker || $0.person != segment.person } ?? false
        let full: Bool = currentChars + segment.text.count > maxChars
        let nearFullAtTurn: Bool = speakerChanged && Double(currentChars) >= Double(maxChars) * 0.8
        if !current.isEmpty, full || nearFullAtTurn {
            chunks.append(current)
            current = []
            currentChars = 0
        }
        current.append(segment)
        currentChars += segment.text.count
    }
    if !current.isEmpty {
        chunks.append(current)
    }
    return chunks
}

/// Görevin bağlamdaki satırı: "3. Aino — Raporu gönder (Cuma)". Saf fonksiyondur.
private func numberedTaskLine(number: Int, task: NoteTask) -> String {
    "\(number). \(task.owner) — \(task.description)\(task.dueDate.map { " (\($0))" } ?? "")"
}

/// Uzun toplantının bir parçası için istek: önceki parçaların özetleri ve şimdiye kadarki numaralı görevler bağlam
/// olarak verilir; model yalnızca bu parçadaki yenileri ve önceki görevlerdeki değişiklikleri yazar. Saf fonksiyondur.
public func noteChunkRequest(
    chunk: [StoredSegment], part: Int, partCount: Int, state: ChunkedNoteState, speakerNames: [Int: String], userName: String,
    template: NoteTemplate, myNotes: String, language: ShareLanguage
) -> LLMRequest {
    let user: String = userName.isEmpty ? "kullanıcı" : userName
    let mine: (rule: String, block: String) = myNotesPrompt(myNotes: myNotes)
    let summaries: String = state.partSummaries.isEmpty ? "(yok, bu ilk parça)" : state.partSummaries.joined(separator: "\n")
    let tasks: String = state.tasks.isEmpty
        ? "(yok)"
        : state.tasks.enumerated().map { numberedTaskLine(number: $0.offset + 1, task: $0.element) }.joined(separator: "\n")
    return LLMRequest(
        tier: .smart,
        system: """
        Uzun bir toplantının (Fince, İngilizce ya da başka bir dilde) transkriptini parça parça okuyup \(language.promptName)
        dilinde toplantı notu çıkarıyorsun. Şu an
        \(partCount) parçanın \(part). parçasındasın. Önceki parçaların özetleri ve şimdiye kadar çıkan numaralı görevler bağlam
        olarak verilir; bu parçayı onlarla bağdaştırarak oku (önceden geçen kişi, konu ve işlere yapılan atıflar).
        Kullanıcının adı \(user); transkriptte "Sen" odur. Yalnızca bu parçadan yaz:
        - ozet: bu parçada konuşulanların 2–5 cümlelik özeti.
        - kararlar: bu parçada alınan kararlar (görevler buraya değil, görevlere).
        - yeniGorevler: bu parçada verilen yeni işler. Listede aynı iş (aynı kişi, aynı konu) zaten varsa yeniden yazma;
          başka bir konunun benzer işi yenidir.
        - degisenGorevler: listedeki bir görev bu parçada değiştiyse (tarih, kapsam) ya da iptal edildiyse numarasıyla yaz.
        - sozluk: bu parçada geçen önemli yabancı dildeki terimler ve \(language.promptName) dilinde anlamları.
        \(noteRules(user: user, template: template, language: language))
        \(mine.rule)
        \(transcriptIsDataNote)
        """,
        userText: """
        \(mine.block)<onceki_parcalar>
        \(summaries)
        </onceki_parcalar>

        <gorevler>
        \(tasks)
        </gorevler>

        <transkript>
        \(storedLines(segments: chunk, speakerNames: speakerNames))
        </transkript>
        """,
        maxTokens: 16000,
        jsonSchema: """
        {"type":"object","properties":{"ozet":{"type":"string"},"kararlar":{"type":"array","items":{"type":"string"}},\
        "yeniGorevler":{"type":"array","items":{"type":"object","properties":{"sahip":{"type":"string"},"aciklama":{"type":"string"},\
        "tarih":{"type":"string"},"benimMi":{"type":"boolean"}},"required":["sahip","aciklama","tarih","benimMi"],"additionalProperties":false}},\
        "degisenGorevler":{"type":"array","items":{"type":"object","properties":{"no":{"type":"integer"},"aciklama":{"type":"string"},\
        "tarih":{"type":"string"},"iptal":{"type":"boolean"}},"required":["no","aciklama","tarih","iptal"],"additionalProperties":false}},\
        "sozluk":{"type":"array","items":{"type":"object","properties":{"terim":{"type":"string"},"anlam":{"type":"string"}},\
        "required":["terim","anlam"],"additionalProperties":false}}},\
        "required":["ozet","kararlar","yeniGorevler","degisenGorevler","sozluk"],"additionalProperties":false}
        """,
        timeoutSec: 300
    )
}

/// Parça yanıtını ayrıştırır; özeti boş parça kullanılamaz (`LLMError.empty`, yeniden istenir).
public func parseNoteChunk(text: String) throws -> NoteChunk {
    let raw: RawNoteChunk
    do {
        raw = try JSONDecoder().decode(RawNoteChunk.self, from: Data(jsonBody(text: text).utf8))
    } catch {
        // Ayrıştırma ayrıntısı (eksik alan vb.) hata ayıklamada gerekir.
        throw LLMError.malformed(body: "\(error): \(text)")
    }
    guard !raw.ozet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw LLMError.empty
    }
    return NoteChunk(
        summary: raw.ozet,
        decisions: raw.kararlar,
        newTasks: raw.yeniGorevler.map { NoteTask(owner: $0.sahip, description: $0.aciklama, dueDate: $0.tarih.isEmpty ? nil : $0.tarih, isMine: $0.benimMi) },
        changedTasks: raw.degisenGorevler.map { TaskChange(number: $0.no, description: $0.aciklama, dueDate: $0.tarih.isEmpty ? nil : $0.tarih, isCancelled: $0.iptal) },
        glossary: raw.sozluk.map { GlossaryEntry(term: $0.terim, meaning: $0.anlam) }
    )
}

/// Parçayı birikmiş nota ekler: önce değişiklikler (numaralar bağlamdaki listeye göre), sonra iptaller düşer, yeni
/// görevler ve kararlar sona eklenir, sözlükte aynı terim (büyük/küçük harf duyarsız) bir kez kalır. Listede olmayan
/// numaraya değişiklik uygulanamaz, yok sayılır. Saf fonksiyondur.
public func applyNoteChunk(state: ChunkedNoteState, chunk: NoteChunk, startSec: Double, endSec: Double) -> ChunkedNoteState {
    let changes: [Int: TaskChange] = Dictionary(chunk.changedTasks.map { ($0.number, $0) }) { (_: TaskChange, last: TaskChange) -> TaskChange in last }
    let updated: [NoteTask] = state.tasks.enumerated().compactMap { (item: (offset: Int, element: NoteTask)) -> NoteTask? in
        guard let change = changes[item.offset + 1] else {
            return item.element
        }
        return change.isCancelled
            ? nil
            : NoteTask(owner: item.element.owner, description: change.description, dueDate: change.dueDate, isMine: item.element.isMine)
    }
    let knownTerms: Set<String> = Set(state.glossary.map { $0.term.lowercased() })
    let newTerms: [GlossaryEntry] = chunk.glossary.reduce(into: [GlossaryEntry]()) { (result: inout [GlossaryEntry], entry: GlossaryEntry) -> Void in
        let key: String = entry.term.lowercased()
        if !knownTerms.contains(key), !result.contains(where: { $0.term.lowercased() == key }) {
            result.append(entry)
        }
    }
    return ChunkedNoteState(
        partSummaries: state.partSummaries + ["[\(timestamp(seconds: startSec))–\(timestamp(seconds: endSec))] \(chunk.summary)"],
        decisions: state.decisions + chunk.decisions,
        tasks: updated + chunk.newTasks,
        glossary: state.glossary + newTerms
    )
}

/// Parçalar bitince başlık ve tüm toplantının özeti için istek (görev ve kararlar yalnızca bağlam; yeniden yazılmaz).
/// Saf fonksiyondur.
public func noteOverviewRequest(state: ChunkedNoteState, userName: String, template: NoteTemplate, myNotes: String, language: ShareLanguage) -> LLMRequest {
    let user: String = userName.isEmpty ? "kullanıcı" : userName
    let mine: (rule: String, block: String) = myNotesPrompt(myNotes: myNotes)
    let tasks: String = state.tasks.enumerated().map { numberedTaskLine(number: $0.offset + 1, task: $0.element) }.joined(separator: "\n")
    return LLMRequest(
        tier: .smart,
        system: """
        Uzun bir toplantının parça parça çıkarılmış notları veriliyor. Kullanıcının adı \(user). Tüm toplantı için
        kısa bir başlık ve konuların akışını, alınan ana kararları ve kullanıcıya düşen önemli işleri anlatan birkaç
        paragraflık özet yaz. Başlık, özet ve akış \(language.promptName) dilinde olur. akis alanına konuların sırasını yaz: her bölümün başladığı [mm:ss] zamanı (parça
        özetlerindeki aralıklardan), kısa başlığı ve tek cümlelik özeti (5–12 bölüm). Notlarda olmayan bir şey uydurma. \(templateInstructions(template: template))
        \(mine.rule)
        \(transcriptIsDataNote)
        """,
        userText: """
        \(mine.block)<parca_ozetleri>
        \(state.partSummaries.joined(separator: "\n"))
        </parca_ozetleri>

        <kararlar>
        \(state.decisions.isEmpty ? "(yok)" : state.decisions.map { "- \($0)" }.joined(separator: "\n"))
        </kararlar>

        <gorevler>
        \(tasks.isEmpty ? "(yok)" : tasks)
        </gorevler>
        """,
        maxTokens: 16000,
        jsonSchema: """
        {"type":"object","properties":{"baslik":{"type":"string"},"ozet":{"type":"string"},\
        "akis":{"type":"array","items":{"type":"object","properties":{"zaman":{"type":"string"},"baslik":{"type":"string"},"ozet":{"type":"string"}},\
        "required":["zaman","baslik","ozet"],"additionalProperties":false}}},\
        "required":["baslik","ozet","akis"],"additionalProperties":false}
        """,
        timeoutSec: 300
    )
}

/// Başlık ve özet yanıtını birikmiş notla birleştirip son notu kurar; özeti boşsa `LLMError.empty`.
public func parseNoteOverview(text: String, state: ChunkedNoteState) throws -> MeetingNote {
    let raw: RawNoteOverview
    do {
        raw = try JSONDecoder().decode(RawNoteOverview.self, from: Data(jsonBody(text: text).utf8))
    } catch {
        throw LLMError.malformed(body: "\(error): \(text)")
    }
    guard !raw.ozet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw LLMError.empty
    }
    let note: MeetingNote = MeetingNote(title: raw.baslik, summary: raw.ozet, decisions: state.decisions, tasks: state.tasks, glossary: state.glossary)
    // Şemayı uygulamayan sunucular (ör. Ollama) akis'i atlayabilir; o zaman not akışsız yazılır.
    return raw.akis.map { note.with(outline: outlineItems(raw: $0)) } ?? note
}

/// Uzun notun kaldığı yer: yazılan parça sayısı ve birikmiş durum. Parmak izi (transkript, adlar, kullanıcı adı,
/// şablon, not dili) tutmazsa baştan başlanır.
public struct ChunkedNoteProgress: Sendable, Equatable, Codable {
    public let fingerprint: String
    public let completedParts: Int
    public let state: ChunkedNoteState

    public init(fingerprint: String, completedParts: Int, state: ChunkedNoteState) {
        self.fingerprint = fingerprint
        self.completedParts = completedParts
        self.state = state
    }
}

/// Not girdilerinin parmak izi (ilerlemenin aynı not için olduğunu doğrular). Saf fonksiyondur.
func noteFingerprint(segments: [StoredSegment], speakerNames: [Int: String], userName: String, template: NoteTemplate, language: ShareLanguage) -> String {
    let names: String = speakerNames.keys.sorted().map { "\($0)=\(speakerNames[$0] ?? "")" }.joined(separator: ",")
    let text: String = segments.map { "\($0.key)|\($0.person.map(String.init) ?? "")|\($0.text)" }.joined(separator: "\n")
    let input: String = [text, names, userName, template.kind.rawValue, template.customInstructions, language.rawValue].joined(separator: "\u{1F}")
    return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
}

private let noteLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ChunkedNote")

/// Kayıtlı ilerleme bu not içinse döner; yoksa, başka nota aitse ya da okunamıyorsa (loglanır) nil.
private func loadedProgress(file: URL, fingerprint: String, partCount: Int) -> ChunkedNoteProgress? {
    guard FileManager.default.fileExists(atPath: file.path) else {
        return nil
    }
    do {
        let progress: ChunkedNoteProgress = try JSONDecoder().decode(ChunkedNoteProgress.self, from: Data(contentsOf: file))
        guard progress.fingerprint == fingerprint, progress.completedParts <= partCount else {
            noteLogger.info("Not ilerlemesi bu transkripte ait değil, baştan yazılıyor")
            return nil
        }
        return progress
    } catch {
        noteLogger.error("Not ilerlemesi okunamadı, baştan yazılıyor, hata: \(String(describing: error), privacy: .public)")
        return nil
    }
}

/// İlerlemeyi atomik yazar; yazılamazsa not yine sürer (yalnızca kaldığı yerden devam edilemez) ve hata loglanır.
private func saveProgress(progress: ChunkedNoteProgress, file: URL) {
    do {
        try JSONEncoder().encode(progress).write(to: file, options: .atomic)
    } catch {
        noteLogger.error("Not ilerlemesi yazılamadı, hata: \(String(describing: error), privacy: .public)")
    }
}

/// Toplantı notunu yazar: kısa transkript tek istekte; uzunu `noteChunkMaxChars`'lık parçalar halinde sırayla (her
/// parça öncekilerin özetini ve görevlerini görür), sonra başlık ve genel özet. Her istek boş/bozuk yanıtta yeniden
/// sorulur. Uzun notta her parçadan sonra ilerleme `progressFile`'a yazılır: bir parça kalıcı olarak başarısız olursa
/// "Tekrar işle" yazılan parçaları yeniden ödemeden kaldığı yerden sürer; not bitince dosya silinir. Not `language`
/// dilinde yazılır. Metin yoksa nil.
public func writeMeetingNote(
    segments: [StoredSegment], speakerNames: [Int: String], userName: String, template: NoteTemplate, myNotes: String, language: ShareLanguage,
    llm: LLMProvider, progressFile: URL
) async throws -> MeetingNote? {
    let totalChars: Int = segments.map(\.text.count).reduce(0, +)
    guard totalChars > noteChunkMaxChars else {
        guard let request = meetingNoteRequest(
            segments: segments, speakerNames: speakerNames, userName: userName, template: template, myNotes: myNotes, language: language
        ) else {
            return nil
        }
        let note: MeetingNote = try await requestStructured(provider: llm, request: request) { (text: String) throws -> MeetingNote in
            try parseMeetingNote(text: text)
        }
        return withNormalizedTasks(note: note, userName: userName).with(language: language)
    }
    let chunks: [[StoredSegment]] = noteChunks(segments: segments, maxChars: noteChunkMaxChars)
    let fingerprint: String = noteFingerprint(
        segments: segments, speakerNames: speakerNames, userName: userName + "\u{1F}" + myNotes, template: template, language: language
    )
    let resumed: ChunkedNoteProgress? = loadedProgress(file: progressFile, fingerprint: fingerprint, partCount: chunks.count)
    if let resumed {
        noteLogger.info("Not kaldığı yerden sürüyor, parça: \(resumed.completedParts, privacy: .public)/\(chunks.count, privacy: .public)")
    }
    var state: ChunkedNoteState = resumed?.state ?? .empty
    for (index, chunk) in chunks.enumerated() where index >= resumed?.completedParts ?? 0 {
        let request: LLMRequest = noteChunkRequest(
            chunk: chunk, part: index + 1, partCount: chunks.count, state: state, speakerNames: speakerNames, userName: userName,
            template: template, myNotes: myNotes, language: language
        )
        let part: NoteChunk = try await requestStructured(provider: llm, request: request) { (text: String) throws -> NoteChunk in
            try parseNoteChunk(text: text)
        }
        // Bağlamdaki görev listesi de tutarlı olsun: sonraki parçalar kullanıcının görevlerini adıyla görür.
        let normalized: NoteChunk = NoteChunk(
            summary: part.summary, decisions: part.decisions,
            newTasks: part.newTasks.map { normalizedTask(task: $0, userName: userName) },
            changedTasks: part.changedTasks, glossary: part.glossary
        )
        state = applyNoteChunk(state: state, chunk: normalized, startSec: chunk.first?.startSec ?? 0, endSec: chunk.last?.endSec ?? 0)
        saveProgress(progress: ChunkedNoteProgress(fingerprint: fingerprint, completedParts: index + 1, state: state), file: progressFile)
    }
    let finalState: ChunkedNoteState = state
    let note: MeetingNote = try await requestStructured(provider: llm, request: noteOverviewRequest(state: finalState, userName: userName, template: template, myNotes: myNotes, language: language)) { (text: String) throws -> MeetingNote in
        try parseNoteOverview(text: text, state: finalState)
    }
    do {
        try FileManager.default.removeItem(at: progressFile)
    } catch {
        noteLogger.error("Not ilerleme dosyası silinemedi, hata: \(String(describing: error), privacy: .public)")
    }
    return withNormalizedTasks(note: note, userName: userName).with(language: language)
}

/// Notun görevlerinde sahibi düzeltilmiş kopya (bkz. `normalizedTask`); konu akışı ve dil korunur. Saf fonksiyondur.
func withNormalizedTasks(note: MeetingNote, userName: String) -> MeetingNote {
    let normalized: MeetingNote = MeetingNote(
        title: note.title, summary: note.summary, decisions: note.decisions,
        tasks: note.tasks.map { normalizedTask(task: $0, userName: userName) }
            // Aynı sahip ve işle iki kez yazılan görev tek görev olur (aynı kimliği paylaşıp birlikte işaretlenmesinler).
            .reduce(into: [NoteTask]()) { (result: inout [NoteTask], task: NoteTask) -> Void in
                if !result.contains(where: { taskKey(task: $0) == taskKey(task: task) }) {
                    result.append(task)
                }
            },
        glossary: note.glossary
    )
    let outlined: MeetingNote = note.outline.map { normalized.with(outline: $0) } ?? normalized
    return note.language.map { outlined.with(language: $0) } ?? outlined
}

// Şemadaki Türkçe alan adları.
private struct RawNoteChunk: Decodable {
    let ozet: String
    let kararlar: [String]
    let yeniGorevler: [RawChunkTask]
    let degisenGorevler: [RawTaskChange]
    let sozluk: [RawChunkGlossary]
}

private struct RawChunkTask: Decodable {
    let sahip: String
    let aciklama: String
    let tarih: String
    let benimMi: Bool
}

private struct RawTaskChange: Decodable {
    let no: Int
    let aciklama: String
    let tarih: String
    let iptal: Bool
}

private struct RawChunkGlossary: Decodable {
    let terim: String
    let anlam: String
}

private struct RawNoteOverview: Decodable {
    let baslik: String
    let ozet: String
    let akis: [RawOutline]?
}

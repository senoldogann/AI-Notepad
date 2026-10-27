import Foundation

/// Sor sohbetinde cevaplanmış bir soru: soru, cevap, kaynakları ve nasıl cevaplandığı (arama terimleri, okunan
/// parçalar, model). Okunan parçalar metinsiz saklanır (yalnız hangi toplantıdan kaç parça okunduğu gösterilir).
public struct AskConversationTurn: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let question: String
    /// `@` ile seçilen toplantılar (soru yalnız onlara soruldu); boşsa tüm arşiv.
    public let scopeMeetingIDs: [String]
    public let scopeTitles: [String]
    /// Soru bir tariften geldiyse tarifin adı.
    public let recipeTitle: String?
    public let startedAt: Date
    public let finishedAt: Date
    public let terms: [String]
    public let readPassages: [ArchivePassage]
    public let answer: String
    public let sources: [ArchivePassage]
    public let modelName: String?

    public init(
        id: UUID, question: String, scopeMeetingIDs: [String], scopeTitles: [String], recipeTitle: String?, startedAt: Date, finishedAt: Date,
        terms: [String], readPassages: [ArchivePassage], answer: String, sources: [ArchivePassage], modelName: String?
    ) {
        self.id = id
        self.question = question
        self.scopeMeetingIDs = scopeMeetingIDs
        self.scopeTitles = scopeTitles
        self.recipeTitle = recipeTitle
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.terms = terms
        self.readPassages = readPassages
        self.answer = answer
        self.sources = sources
        self.modelName = modelName
    }
}

/// Saklanan bir Sor sohbeti (`AskHistory/<id>.json`). Başlık ilk sorudur.
public struct AskConversation: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let title: String
    public let turns: [AskConversationTurn]

    public init(id: UUID, createdAt: Date, updatedAt: Date, title: String, turns: [AskConversationTurn]) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.turns = turns
    }
}

/// Saklanan en fazla sohbet; daha eskileri silinir.
public let askHistoryLimit: Int = 200

/// Sohbet başlığının en fazla uzunluğu (karakter).
let askConversationTitleChars: Int = 80

/// Okunamayan sohbet dosyası.
public struct AskHistoryLoadFailure: Error, Sendable, Equatable {
    public let file: String
    public let reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// Saklanan sohbetler (yeniden eskiye) ve okunamayan dosyalar; bir bozuk dosya diğerlerini engellemez.
public struct AskHistoryLoadResult: Sendable, Equatable {
    public let conversations: [AskConversation]
    public let failures: [AskHistoryLoadFailure]
}

/// Sohbetin başlığı: ilk sorunun (tariften geldiyse tarifin adının) tek satırlık, kısaltılmış hali. Saf fonksiyondur.
public func askConversationTitle(turn: AskConversationTurn) -> String {
    let text: String = turn.recipeTitle ?? turn.question
    let line: String = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.count > askConversationTitleChars ? String(line.prefix(askConversationTitleChars - 1)) + "…" : line
}

/// Sohbetin güncel hali: turlar değişir, başlık ilk turdan, oluşturulma zamanı varsa eski sohbetten gelir. Saf
/// fonksiyondur.
public func askConversation(existing: AskConversation?, id: UUID, turns: [AskConversationTurn], now: Date) -> AskConversation {
    AskConversation(
        id: id, createdAt: existing?.createdAt ?? now, updatedAt: now,
        title: turns.first.map { askConversationTitle(turn: $0) } ?? "", turns: turns
    )
}

/// Sohbeti listeye yazar (aynı kimlikli eskisinin yerine) ve listeyi yeniden eskiye sıralar. Saf fonksiyondur.
public func upsertAskConversation(conversations: [AskConversation], conversation: AskConversation) -> [AskConversation] {
    newestAskConversationsFirst(conversations: conversations.filter { $0.id != conversation.id } + [conversation])
}

/// Sohbetler, en son güncellenen önce. Saf fonksiyondur.
func newestAskConversationsFirst(conversations: [AskConversation]) -> [AskConversation] {
    conversations.sorted { (first: AskConversation, second: AskConversation) -> Bool in
        first.updatedAt != second.updatedAt ? first.updatedAt > second.updatedAt : first.id.uuidString < second.id.uuidString
    }
}

/// Sınırı aşan (en eski) sohbetler: silinecekler. Saf fonksiyondur.
public func askConversationsBeyondLimit(conversations: [AskConversation], limit: Int) -> [AskConversation] {
    Array(newestAskConversationsFirst(conversations: conversations).dropFirst(limit))
}

/// Sohbetin dosyası: `<klasör>/<id>.json`.
func askConversationFile(id: UUID, directory: URL) -> URL {
    directory.appending(path: "\(id.uuidString).json")
}

/// Sohbeti klasöründeki dosyasına atomik yazar.
public func saveAskConversation(conversation: AskConversation, directory: URL) throws {
    let file: URL = askConversationFile(id: conversation.id, directory: directory)
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data: Data
    do {
        data = try encoder.encode(conversation)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
    do {
        try data.write(to: file, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Klasördeki tüm sohbetleri okur (yeniden eskiye). Klasör yoksa boş; okunamayan dosyalar `failures`'a yazılır.
public func loadAskConversations(directory: URL) throws -> AskHistoryLoadResult {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return AskHistoryLoadResult(conversations: [], failures: [])
    }
    let files: [URL]
    do {
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    } catch {
        throw StorageError.readFailed(path: directory.path, reason: error.localizedDescription)
    }
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let loaded: [Result<AskConversation, AskHistoryLoadFailure>] = files.map { (file: URL) -> Result<AskConversation, AskHistoryLoadFailure> in
        do {
            return .success(try decoder.decode(AskConversation.self, from: Data(contentsOf: file)))
        } catch {
            return .failure(AskHistoryLoadFailure(file: file.lastPathComponent, reason: error.localizedDescription))
        }
    }
    let conversations: [AskConversation] = loaded.compactMap { (result: Result<AskConversation, AskHistoryLoadFailure>) -> AskConversation? in
        if case .success(let conversation) = result {
            return conversation
        }
        return nil
    }
    let failures: [AskHistoryLoadFailure] = loaded.compactMap { (result: Result<AskConversation, AskHistoryLoadFailure>) -> AskHistoryLoadFailure? in
        if case .failure(let failure) = result {
            return failure
        }
        return nil
    }
    return AskHistoryLoadResult(conversations: newestAskConversationsFirst(conversations: conversations), failures: failures)
}

/// Sohbetin dosyasını siler; dosya zaten yoksa bir şey yapmaz.
public func deleteAskConversation(id: UUID, directory: URL) throws {
    let file: URL = askConversationFile(id: id, directory: directory)
    guard FileManager.default.fileExists(atPath: file.path) else {
        return
    }
    do {
        try FileManager.default.removeItem(at: file)
    } catch {
        throw StorageError.deleteFailed(path: file.path, reason: error.localizedDescription)
    }
}

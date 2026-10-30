import AINotepadCore
import Foundation
import Testing
@testable import AINotepadUI

/// Bitmiş bir soru: `@` kapsamı ve (varsa) tarif adıyla.
private func finished(question: String, scope: [String], recipeTitle: String?) -> ArchiveExchange {
    ArchiveExchange(
        id: UUID(), question: question, scopeMeetingIDs: scope, scopeTitles: scope.map { "Toplantı \($0)" }, recipeTitle: recipeTitle,
        startedAt: Date(timeIntervalSince1970: 1_792_000_000), phase: .done, terms: [], passages: [],
        answer: ArchiveAnswer(text: "Cevap", sources: []), finishedAt: Date(timeIntervalSince1970: 1_792_000_005), modelName: nil
    )
}

@Suite struct AskChatTests {
    // Boş alanda ↑: kullanıcının yazdığı son soru gelir; tariften gelen uzun istem atlanır, soru yoksa nil.
    @Test func lastAskedQuestionSkipsRecipes() {
        let typed: ArchiveExchange = finished(question: "Bütçe ne oldu?", scope: [], recipeTitle: nil)
        let recipe: ArchiveExchange = finished(question: "Uzun tarif istemi…", scope: [], recipeTitle: "Takip e-postası")
        #expect(lastAskedQuestion(exchanges: [typed, recipe]) == "Bütçe ne oldu?")
        #expect(lastAskedQuestion(exchanges: [recipe]) == nil)
        #expect(lastAskedQuestion(exchanges: []) == nil)
    }

    // Saklanan tur sohbete geri açılınca `@` etiketleri (kimlik ve başlık) aynen görünür.
    @Test func reopenedTurnKeepsMentionChips() throws {
        let exchange: ArchiveExchange = finished(question: "Kim ne üstlendi?", scope: ["a", "b"], recipeTitle: nil)
        let turn: AskConversationTurn = try #require(askTurn(exchange: exchange))
        let reopened: ArchiveExchange = archiveExchange(turn: turn)
        #expect(reopened.scopeMeetingIDs == ["a", "b"])
        #expect(reopened.scopeTitles == ["Toplantı a", "Toplantı b"])
        #expect(reopened == exchange)
    }
}

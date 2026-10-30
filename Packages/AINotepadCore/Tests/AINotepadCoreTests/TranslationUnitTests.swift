import Foundation
import Testing
@testable import AINotepadCore

/// Deepgram benzeri kesin bölüm: verilen başlangıç ve bitişle.
private func fragment(_ index: Int, _ start: Double, _ end: Double, _ text: String, person: Int?) -> LiveSegment {
    LiveSegment(id: SegmentID(speaker: .others, index: index), startSec: start, endSec: end, text: text, isFinal: true, failureMessage: nil, person: person)
}

/// Bölümleri sırayla (her biri `nowStep` saniye arayla gelmiş gibi) kurucuya verir; hazır birimleri toplar.
private func feed(fragments: [LiveSegment], builder: TranslationUnitBuilder, nowStep: Double) -> TranslationUnitStep {
    fragments.enumerated().reduce(TranslationUnitStep(builder: builder, ready: [])) { (step: TranslationUnitStep, item: (offset: Int, element: LiveSegment)) -> TranslationUnitStep in
        let next: TranslationUnitStep = addingFinal(builder: step.builder, segment: item.element, nowSec: Double(item.offset) * nowStep, limits: liveTranslationUnitLimits)
        return TranslationUnitStep(builder: next.builder, ready: step.ready + next.ready)
    }
}

/// Üretimde görülen Fince haber yayını: Deepgram cümle ortasında kesinleştirdi.
private let finnishBroadcast: [LiveSegment] = [
    fragment(0, 0, 4.2, "Tässä on siis Suomen hävittäjävalinta nykyisten hornettien korvaajaksi.", person: nil),
    fragment(1, 4.2, 8.9, "Kyseessä on yhdysvaltalaisen Lockheed Martin yhtiön F35-monitoimihävittäjä.", person: nil),
    fragment(2, 8.9, 12.1, "F-kolmekymmentäviisi:stä saamamme tarjouksen hinta-", person: nil),
    fragment(3, 12.1, 13.6, "laatusuhde on hyvä.", person: nil),
    fragment(4, 13.6, 16.0, "siipien kärkiväli on noin yksi", person: nil),
    fragment(5, 16.0, 20.4, "toista metriä ja koneen pituus on vajaat kuusitoista metriä,", person: nil),
]

@Suite struct TranslationUnitTests {
    @Test func sentenceEnds() {
        #expect(endsSentence(text: "laatusuhde on hyvä."))
        #expect(endsSentence(text: "Tuletko? "))
        #expect(endsSentence(text: "Hän sanoi: \"Tule tänne!\""))
        #expect(endsSentence(text: "(näin on.)"))
        #expect(endsSentence(text: "No niin…"))
        #expect(endsSentence(text: "好的。"))
        #expect(!endsSentence(text: "tarjouksen hinta-"))
        #expect(!endsSentence(text: "kuusitoista metriä,"))
        #expect(!endsSentence(text: ""))
    }

    // Kelime ortasında kesilen bileşik kelime boşluksuz birleşir; diğerleri boşlukla.
    @Test func joinsHyphenatedCompound() {
        #expect(joinedUnitText(texts: ["tarjouksen hinta-", "laatusuhde on hyvä."]) == "tarjouksen hinta-laatusuhde on hyvä.")
        #expect(joinedUnitText(texts: ["noin yksi", " toista metriä"]) == "noin yksi toista metriä")
        #expect(joinedUnitText(texts: ["sanoi -", "ja meni."]) == "sanoi - ja meni.")
    }

    // Noktalamasız parçalar birleşir; cümle sonu birimi kapatır; tam cümle tek başına birimdir.
    @Test func fragmentsJoinUntilSentenceEnd() throws {
        let step: TranslationUnitStep = feed(fragments: finnishBroadcast, builder: .empty, nowStep: 1)
        #expect(step.ready.map(\.segmentIDs.count) == [1, 1, 2])
        let joined: TranslationUnit = try #require(step.ready.last)
        #expect(joined.text == "F-kolmekymmentäviisi:stä saamamme tarjouksen hinta-laatusuhde on hyvä.")
        #expect(joined.carrierID == finnishBroadcast[3].id)
        #expect(joined.coveredIDs == [finnishBroadcast[2].id])
        #expect(joined.startSec == 8.9)
        #expect(joined.endSec == 13.6)
        // Cümlesi bitmeyen son iki parça bekler.
        #expect(step.builder.pendingSegments(speaker: .others).map(\.id) == [finnishBroadcast[4].id, finnishBroadcast[5].id])
    }

    // Cümle sonu gelmeden konuşmacı susarsa yarım birim sessizlik süresi dolunca çevrilir; erken değil.
    @Test func idleFlushAfterSilence() throws {
        let step: TranslationUnitStep = feed(fragments: Array(finnishBroadcast[4...5]), builder: .empty, nowStep: 1)
        #expect(step.ready.isEmpty)
        // Son bölüm 1. saniyede geldi.
        let early: TranslationUnitStep = flushingIdle(builder: step.builder, nowSec: 1 + liveTranslationUnitLimits.idleSec - 0.1, limits: liveTranslationUnitLimits)
        #expect(early.ready.isEmpty)
        #expect(early.builder == step.builder)
        let due: TranslationUnitStep = flushingIdle(builder: step.builder, nowSec: 1 + liveTranslationUnitLimits.idleSec, limits: liveTranslationUnitLimits)
        let unit: TranslationUnit = try #require(due.ready.first)
        #expect(due.ready.count == 1)
        #expect(unit.text == "siipien kärkiväli on noin yksi toista metriä ja koneen pituus on vajaat kuusitoista metriä,")
        #expect(due.builder.pending.isEmpty)
    }

    // Kayıt sonunda bekleyen her şey birim olur.
    @Test func flushAllAtRecordingEnd() {
        let step: TranslationUnitStep = feed(fragments: finnishBroadcast, builder: .empty, nowStep: 0.5)
        let end: TranslationUnitStep = flushingAll(builder: step.builder)
        #expect(end.ready.map(\.segmentIDs) == [[finnishBroadcast[4].id, finnishBroadcast[5].id]])
        #expect(end.builder.pending.isEmpty)
        #expect(flushingAll(builder: end.builder).ready.isEmpty)
    }

    // Noktalama hiç gelmezse birim en uzun süreye ulaşınca kapanır.
    @Test func maxDurationClosesUnit() {
        let fragments: [LiveSegment] = (0..<6).map { (index: Int) -> LiveSegment in
            fragment(index, Double(index) * 4, Double(index) * 4 + 4, "sana\(index) ilman pistettä", person: nil)
        }
        let step: TranslationUnitStep = feed(fragments: fragments, builder: .empty, nowStep: 1)
        // 0–16 sn (≥15) kapanır, 16–24 sn bekler.
        #expect(step.ready.map(\.segmentIDs.count) == [4])
        #expect(step.ready.first?.endSec == 16)
        #expect(step.builder.pendingSegments(speaker: .others).count == 2)
    }

    // Noktalamasız uzun metin en uzun karakter sayısında kapanır.
    @Test func maxLengthClosesUnit() {
        let long: String = String(repeating: "sana ", count: 50)
        let fragments: [LiveSegment] = [fragment(0, 0, 1, long, person: nil), fragment(1, 1, 2, long, person: nil)]
        let step: TranslationUnitStep = feed(fragments: fragments, builder: .empty, nowStep: 1)
        #expect(step.ready.map(\.segmentIDs.count) == [2])
    }

    // Konuşmacılar ayrı birikir: "Sen"in bölümü "Diğerleri"nin yarım cümlesine karışmaz; bilinen iki kişi arasında
    // birim kapanır.
    @Test func speakersStaySeparate() {
        let mine: LiveSegment = LiveSegment(id: SegmentID(speaker: .me, index: 0), startSec: 1, endSec: 2, text: "joo", isFinal: true, failureMessage: nil, person: nil)
        let step: TranslationUnitStep = feed(fragments: [fragment(0, 0, 1, "ensin tämä", person: nil), mine, fragment(1, 2, 3, "ja sitten.", person: nil)], builder: .empty, nowStep: 1)
        #expect(step.ready.map(\.segmentIDs) == [[SegmentID(speaker: .others, index: 0), SegmentID(speaker: .others, index: 1)]])
        #expect(step.builder.pendingSegments(speaker: .me).map(\.id) == [mine.id])

        let persons: TranslationUnitStep = feed(
            fragments: [fragment(0, 0, 1, "minä sanon", person: 1), fragment(1, 1, 2, "sinä sanot.", person: 2)], builder: .empty, nowStep: 1
        )
        #expect(persons.ready.map(\.segmentIDs.count) == [1, 1])
    }

    // Aynı bölüm iki kez birime girmez (yeniden gelen kesin sonuç, "Sadece orijinal"den dönüş); bekleyen bölüm aynı
    // kimlikle yeniden gelirse yenisi geçerlidir.
    @Test func neverDuplicates() {
        let first: TranslationUnitStep = feed(fragments: Array(finnishBroadcast[0...3]), builder: .empty, nowStep: 1)
        let again: TranslationUnitStep = feed(fragments: Array(finnishBroadcast[0...3]), builder: first.builder, nowStep: 1)
        #expect(again.ready.isEmpty)
        #expect(again.builder.pending.isEmpty)

        let pending: TranslationUnitStep = feed(fragments: [fragment(0, 0, 1, "alku", person: nil)], builder: .empty, nowStep: 1)
        let corrected: TranslationUnitStep = feed(fragments: [fragment(0, 0, 1, "alku on tässä.", person: nil)], builder: pending.builder, nowStep: 1)
        #expect(corrected.ready.map(\.text) == ["alku on tässä."])
        let all: [SegmentID] = (first.ready + again.ready).flatMap(\.segmentIDs)
        #expect(Set(all).count == all.count)
    }

    // Kapanmış birimlerden önce biten geç bölüm (doldurulan boşluk) tek başına birimdir; açık birime karışmaz.
    @Test func lateGapFillIsOwnUnit() {
        let step: TranslationUnitStep = feed(
            fragments: [fragment(0, 0, 2, "Ensimmäinen lause.", person: nil), fragment(1, 5, 7, "Toinen lause.", person: nil), fragment(2, 7, 8, "kolmas alkaa", person: nil)],
            builder: .empty, nowStep: 1
        )
        let gap: LiveSegment = fragment(1_000_000, 2, 5, "välissä puhuttiin", person: 1)
        let late: TranslationUnitStep = addingFinal(builder: step.builder, segment: gap, nowSec: 3, limits: liveTranslationUnitLimits)
        #expect(late.ready.map(\.segmentIDs) == [[gap.id]])
        #expect(late.builder.pendingSegments(speaker: .others).map(\.id) == [SegmentID(speaker: .others, index: 2)])
    }

    // Boş, hatalı ve kesinleşmemiş bölümler birime girmez.
    @Test func ignoresNonTranslatable() {
        let partial: LiveSegment = LiveSegment(id: SegmentID(speaker: .others, index: 0), startSec: 0, endSec: 1, text: "kesken", isFinal: false, failureMessage: nil, person: nil)
        let failed: LiveSegment = LiveSegment(id: SegmentID(speaker: .others, index: 1), startSec: 0, endSec: 1, text: "", isFinal: true, failureMessage: "virhe", person: nil)
        let blank: LiveSegment = fragment(2, 0, 1, "  ", person: nil)
        let step: TranslationUnitStep = feed(fragments: [partial, failed, blank], builder: .empty, nowStep: 1)
        #expect(step.ready.isEmpty)
        #expect(step.builder == .empty)
    }

    // Çeviri son bölüme, önceki bölümlere boş çeviri (kapsandı); "Tekrar dene" bütün birimi bulur; bağlam önceki birimler.
    @Test func storesTranslationOnCarrier() {
        let step: TranslationUnitStep = feed(fragments: Array(finnishBroadcast[0...3]), builder: .empty, nowStep: 1)
        let unit: TranslationUnit = step.ready[2]
        let translations: [SegmentID: String] = applyingUnitTranslation(translations: [:], unit: unit, translation: "Fiyat-performans oranı iyi.")
        #expect(translations == [finnishBroadcast[2].id: "", finnishBroadcast[3].id: "Fiyat-performans oranı iyi."])
        #expect(unitsContaining(ids: [finnishBroadcast[2].id], units: step.ready) == [unit])
        #expect(unitsContaining(ids: [finnishBroadcast[3].id, finnishBroadcast[2].id], units: step.ready) == [unit])
        #expect(translationContext(units: step.ready, before: unit, count: 1) == [finnishBroadcast[1].text])
        #expect(translationContext(units: step.ready, before: step.ready[0], count: 3).isEmpty)
    }

    // Son geçiş: birimin çevirisi birimin tüm süresiyle en çok kesişen son geçiş bölümüne taşınır; kapsananlar boş kalmaz.
    @Test func alignsUnitTranslationsToFinalPass() {
        let live: [StoredSegment] = [
            StoredSegment(key: "others-0", speaker: .others, person: nil, startSec: 0, endSec: 4, text: "a", words: nil),
            StoredSegment(key: "others-1", speaker: .others, person: nil, startSec: 4, endSec: 5, text: "b.", words: nil),
            StoredSegment(key: "others-2", speaker: .others, person: nil, startSec: 5, endSec: 9, text: "c.", words: nil),
        ]
        let final: [StoredSegment] = [
            StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 3.5, text: "a", words: nil),
            StoredSegment(key: "final-1", speaker: .others, person: 1, startSec: 3.5, endSec: 9, text: "b. c.", words: nil),
        ]
        let aligned: [String: String] = alignTranslations(final: final, live: live, translations: ["others-0": "", "others-1": "AB.", "others-2": "C."])
        // Birim 0–5 sn: final-0 ile 3,5 sn, final-1 ile 1,5 sn kesişir.
        #expect(aligned == ["final-0": "AB.", "final-1": "C."])
    }

    // Toplantılar penceresi: kapsanan bölümün boş çevirisi paragraf çevirisine boşluk katmaz.
    @Test func paragraphsSkipCoveredTranslations() {
        let record: MeetingRecord = MeetingRecord(
            id: "x", title: "T", startedAt: Date(), endedAt: nil, language: .finnish, status: .done, failureMessage: nil,
            liveSegments: [
                StoredSegment(key: "others-0", speaker: .others, person: nil, startSec: 0, endSec: 3, text: "hinta-", words: nil),
                StoredSegment(key: "others-1", speaker: .others, person: nil, startSec: 3, endSec: 5, text: "laatusuhde on hyvä.", words: nil),
            ],
            finalSegments: [], translations: ["others-0": "", "others-1": "Fiyat-performans oranı iyi."], speakerNames: [:], note: nil,
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        #expect(transcriptParagraphs(record: record).map(\.turkish) == ["Fiyat-performans oranı iyi."])
    }
}

extension CloudTests {
/// Gerçek modelle canlı çeviri: Deepgram'ın cümle ortasında kestiği Fince yayın birimlerle çevrilir; ifade tekrarı ve
/// çevrilmeden kalan Fince kelime olmamalı.
@Suite struct LiveTranslationUnitCloudTests {
    @Test func translatesFinnishBroadcastBySentenceUnits() async throws {
        let provider: LLMProvider = .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic)))
        let built: TranslationUnitStep = feed(fragments: finnishBroadcast, builder: .empty, nowStep: 1)
        let end: TranslationUnitStep = flushingAll(builder: built.builder)
        let units: [TranslationUnit] = built.ready + end.ready
        #expect(units.map(\.segmentIDs.count) == [1, 1, 2, 2])
        var outputs: [String] = []
        for unit in units {
            let context: [String] = translationContext(units: units, before: unit, count: 3)
            outputs.append(try await translateSentence(provider: provider, sentence: unit.text, context: context, language: .turkish))
        }
        let all: String = outputs.joined(separator: " ")
        print("Canlı çeviri (birimlerle):\n" + outputs.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        let words: [String] = all.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
        // Türkçede de geçebilen kısa kelimeler ("on" = 10) listede yok.
        let finnish: Set<String> = [
            "että", "kyseessä", "tässä", "siis", "nykyisten", "korvaajaksi", "yhdysvaltalaisen", "yhtiön", "saamamme", "tarjouksen",
            "laatusuhde", "hyvä", "siipien", "kärkiväli", "noin", "yksi", "toista", "metriä", "ja", "koneen", "pituus", "vajaat", "kuusitoista",
        ]
        #expect(Set(words).isDisjoint(with: finnish), "Fince kelime kaldı: \(Set(words).intersection(finnish)) — \(all)")
        // Art arda tekrar eden 2–4 kelimelik ifade yok ("fiyat-performans oranı fiyat-performans oranı").
        for length in 2...4 where words.count >= length * 2 {
            for start in 0...(words.count - length * 2) {
                let first: ArraySlice<String> = words[start..<(start + length)]
                let second: ArraySlice<String> = words[(start + length)..<(start + length * 2)]
                #expect(first != second, "tekrar eden ifade: \(first.joined(separator: " ")) — \(all)")
            }
        }
    }
}
}

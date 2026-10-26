import Foundation
import Testing
@testable import AINotepadCore

@Suite struct CloudPureTests {
    @Test func reconnectDelaysCoverBudgetWithCap() {
        let delays: [Double] = reconnectDelays(budgetSec: 60, initialSec: 0.25, capSec: 5)
        #expect(delays.prefix(5) == [0.25, 0.5, 1, 2, 4])
        #expect(delays.dropFirst(5).allSatisfy { $0 == 5 })
        #expect(delays.reduce(0, +) >= 60)
        #expect(delays.dropLast().reduce(0, +) < 60)
    }

    @Test func emptyFinalIsPassedThrough() {
        let result: DeepgramResult = DeepgramResult(startSec: 1, endSec: 2, transcript: "", isFinal: true)
        #expect(streamingEvent(result: result, connectionStartSample: 16000, sampleRate: 16000) == .final(text: "", startSec: 2, endSec: 3))
    }

    @Test func emptyPartialIsDropped() {
        let result: DeepgramResult = DeepgramResult(startSec: 1, endSec: 2, transcript: "", isFinal: false)
        #expect(streamingEvent(result: result, connectionStartSample: 0, sampleRate: 16000) == nil)
    }

    @Test func appendUniqueSkipsRepeats() {
        #expect(appendUnique(messages: ["a"], message: "a") == ["a"])
        #expect(appendUnique(messages: ["a"], message: "b") == ["a", "b"])
    }
}

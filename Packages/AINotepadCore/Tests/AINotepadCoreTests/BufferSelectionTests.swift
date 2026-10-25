import CoreAudio
import Foundation
import Testing
@testable import AINotepadCore

/// Verilen bayt boyutlarıyla (boş veri) bir tampon listesi oluşturur.
func makeBufferList(byteSizes: [UInt32]) -> UnsafeMutableAudioBufferListPointer {
    let list: UnsafeMutableAudioBufferListPointer = AudioBufferList.allocate(maximumBuffers: byteSizes.count)
    for (index, size) in byteSizes.enumerated() {
        list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: size, mData: nil)
    }
    return list
}

@Suite struct BufferSelectionTests {
    // Alt cihazın (ör. AirPods mikrofonu) akışları önce, tap akışı en sonda gelir.
    @Test func picksTrailingTapBuffer() {
        let source: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [10, 20, 30])
        let destination: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [0])
        #expect(copyTrailingBuffers(source: source, destination: destination))
        #expect(destination[0].mDataByteSize == 30)
        free(source.unsafeMutablePointer)
        free(destination.unsafeMutablePointer)
    }

    @Test func picksTrailingNonInterleavedChannels() {
        let source: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [10, 20, 30])
        let destination: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [0, 0])
        #expect(copyTrailingBuffers(source: source, destination: destination))
        #expect(destination.map(\.mDataByteSize) == [20, 30])
        free(source.unsafeMutablePointer)
        free(destination.unsafeMutablePointer)
    }

    @Test func failsWhenSourceHasTooFewBuffers() {
        let source: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [10])
        let destination: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [0, 0])
        #expect(!copyTrailingBuffers(source: source, destination: destination))
        free(source.unsafeMutablePointer)
        free(destination.unsafeMutablePointer)
    }
}

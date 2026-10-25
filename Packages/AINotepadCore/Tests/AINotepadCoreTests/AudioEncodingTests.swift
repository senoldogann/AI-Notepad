import Foundation
import Testing
@testable import AINotepadCore

@Suite struct AudioEncodingTests {
    @Test func linear16ClampsAndEncodesLittleEndian() {
        let data: Data = linear16Data(samples: [0, 1, -1, 2])
        #expect(Array(data) == [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x7F])
    }

    @Test func wavHeaderDescribes16kMono() {
        let data: Data = wavData(samples: [Float](repeating: 0, count: 16000), sampleRate: 16000)
        let bytes: [UInt8] = Array(data)
        func u32(_ offset: Int) -> UInt32 { bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        #expect(data.count == 44 + 32000)
        #expect(String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE")
        #expect(u16(20) == 1)        // PCM
        #expect(u16(22) == 1)        // kanal
        #expect(u32(24) == 16000)    // örnekleme
        #expect(u16(34) == 16)       // bit
        #expect(String(decoding: bytes[36..<40], as: UTF8.self) == "data")
        #expect(u32(40) == 32000)
    }
}

import Foundation

/// Float örnekleri ([-1, 1] aralığına kırparak) 16-bit little-endian PCM'e çevirir.
public func linear16Data(samples: [Float]) -> Data {
    var data: Data = Data(capacity: samples.count * 2)
    for sample in samples {
        let clamped: Float = max(-1, min(1, sample))
        let value: Int16 = Int16((clamped * Float(Int16.max)).rounded())
        withUnsafeBytes(of: value.littleEndian) { (bytes: UnsafeRawBufferPointer) -> Void in data.append(contentsOf: bytes) }
    }
    return data
}

/// Mono 16-bit PCM WAV dosyası üretir (44 baytlık RIFF başlığı + veri).
public func wavData(samples: [Float], sampleRate: Int) -> Data {
    let pcm: Data = linear16Data(samples: samples)
    var data: Data = Data(capacity: 44 + pcm.count)
    data.append(contentsOf: Array("RIFF".utf8))
    appendLittleEndian(data: &data, value: UInt32(36 + pcm.count))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    appendLittleEndian(data: &data, value: UInt32(16))            // fmt bölüm boyutu
    appendLittleEndian(data: &data, value: UInt16(1))             // PCM
    appendLittleEndian(data: &data, value: UInt16(1))             // kanal
    appendLittleEndian(data: &data, value: UInt32(sampleRate))
    appendLittleEndian(data: &data, value: UInt32(sampleRate * 2)) // bayt/sn
    appendLittleEndian(data: &data, value: UInt16(2))             // blok hizası
    appendLittleEndian(data: &data, value: UInt16(16))            // bit
    data.append(contentsOf: Array("data".utf8))
    appendLittleEndian(data: &data, value: UInt32(pcm.count))
    data.append(pcm)
    return data
}

private func appendLittleEndian<Value: FixedWidthInteger>(data: inout Data, value: Value) {
    withUnsafeBytes(of: value.littleEndian) { (bytes: UnsafeRawBufferPointer) -> Void in data.append(contentsOf: bytes) }
}

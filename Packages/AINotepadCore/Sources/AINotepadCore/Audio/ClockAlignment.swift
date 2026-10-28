import Foundation

/// Gelen parçadan önce eklenecek sessizlik (örnek sayısı): parçanın başlaması gereken an ile şimdiye kadar
/// verilen ses arasındaki açık `thresholdSec`'i aşıyorsa açığın tamamı. Parça yakalandıktan sonra geldiği için
/// başlangıcı "şimdi − parça süresi" sayılır. Saf fonksiyondur.
///
/// Böylece akış geç başladığında (izin penceresi) ya da cihaz değişiminde yakalama yeniden kurulurken
/// "Sen" ve "Diğerleri" aynı zaman çizgisinde kalır.
public func gapFillSamples(elapsedSec: Double, emittedSamples: Int, chunkSamples: Int, sampleRate: Int, thresholdSec: Double) -> Int {
    let chunkStartSample: Int = Int((elapsedSec * Double(sampleRate)).rounded()) - chunkSamples
    let gap: Int = chunkStartSample - emittedSamples
    return Double(gap) > thresholdSec * Double(sampleRate) ? gap : 0
}

/// Sessizlik dolgusunu en fazla `maxChunkSamples` uzunluğunda parçalara böler (parça uzunlukları). Saf fonksiyondur.
///
/// Uzun bir boşluk (ör. kapak kapalıyken saat ilerledi) tek dev dizi olarak ayrılıp kopyalanmasın diye dolgu
/// sınırlı parçalarla verilir.
public func silenceChunkLengths(totalSamples: Int, maxChunkSamples: Int) -> [Int] {
    guard totalSamples > 0, maxChunkSamples > 0 else {
        return []
    }
    let fullChunks: Int = totalSamples / maxChunkSamples
    let remainder: Int = totalSamples % maxChunkSamples
    return [Int](repeating: maxChunkSamples, count: fullChunks) + (remainder > 0 ? [remainder] : [])
}

/// Ses akışını kaydın başladığı ana (`origin`) hizalar: akıştaki boşluklar sessizlikle doldurulur (en fazla 1 sn'lik
/// parçalarla). Saatler arasındaki küçük kaymalar (`thresholdSec` altı) düzeltilmez.
public func clockAlignedStream(
    audio: AsyncStream<[Float]>,
    origin: ContinuousClock.Instant,
    sampleRate: Int,
    thresholdSec: Double
) -> AsyncStream<[Float]> {
    let (aligned, sink): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    let task: Task<Void, Never> = Task {
        var emitted: Int = 0
        for await chunk in audio {
            let elapsed: Duration = ContinuousClock.now - origin
            let elapsedSec: Double = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let fill: Int = gapFillSamples(
                elapsedSec: elapsedSec, emittedSamples: emitted, chunkSamples: chunk.count, sampleRate: sampleRate, thresholdSec: thresholdSec
            )
            for length in silenceChunkLengths(totalSamples: fill, maxChunkSamples: sampleRate) {
                sink.yield([Float](repeating: 0, count: length))
            }
            sink.yield(chunk)
            emitted += fill + chunk.count
        }
        sink.finish()
    }
    sink.onTermination = { (_: AsyncStream<[Float]>.Continuation.Termination) -> Void in
        task.cancel()
    }
    return aligned
}

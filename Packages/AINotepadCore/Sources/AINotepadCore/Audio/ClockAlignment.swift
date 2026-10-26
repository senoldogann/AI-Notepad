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

/// Ses akışını kaydın başladığı ana (`origin`) hizalar: akıştaki boşluklar sessizlikle doldurulur.
/// Saatler arasındaki küçük kaymalar (`thresholdSec` altı) düzeltilmez.
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
            if fill > 0 {
                sink.yield([Float](repeating: 0, count: fill))
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

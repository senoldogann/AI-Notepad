import Foundation

/// Enerji tabanlı konuşma bölümleyicinin ayarları.
public struct SegmenterConfig: Sendable, Equatable {
    public let sampleRate: Int
    /// Enerji ölçümü yapılan çerçevenin örnek sayısı.
    public let frameSamples: Int
    /// Bu RMS değerinin üstündeki çerçeveler konuşma sayılır.
    public let energyThreshold: Float
    /// Bölümü kapatan en kısa sessizlik.
    public let minSilenceSec: Double
    /// Bir bölümün en fazla uzunluğu; aşılınca bölüm sessizlik beklenmeden kapatılır.
    public let maxSegmentSec: Double
    /// Bundan kısa konuşmalar (öksürük, tık sesi) atılır.
    public let minSpeechSec: Double

    public init(
        sampleRate: Int,
        frameSamples: Int,
        energyThreshold: Float,
        minSilenceSec: Double,
        maxSegmentSec: Double,
        minSpeechSec: Double
    ) {
        self.sampleRate = sampleRate
        self.frameSamples = frameSamples
        self.energyThreshold = energyThreshold
        self.minSilenceSec = minSilenceSec
        self.maxSegmentSec = maxSegmentSec
        self.minSpeechSec = minSpeechSec
    }

    /// Canlı transkripsiyon için ayarlar: 16 kHz, 100 ms çerçeve, 0.6 sn sessizlik, en fazla 15 sn.
    public static let live: SegmenterConfig = SegmenterConfig(
        sampleRate: 16000,
        frameSamples: 1600,
        energyThreshold: 0.01,
        minSilenceSec: 0.6,
        maxSegmentSec: 15,
        minSpeechSec: 0.3
    )
}

/// Henüz kapanmamış, büyümekte olan bölüm.
public struct OpenSegment: Sendable, Equatable {
    public let index: Int
    /// Bölümün akıştaki ilk örneğinin konumu.
    public let startSample: Int
    public let samples: [Float]
    /// Bölümün sonundaki kesintisiz sessizliğin örnek sayısı.
    public let trailingSilenceSamples: Int
}

/// Kapanmış ve yazıya dökülmeye hazır bölüm.
public struct ClosedSegment: Sendable, Equatable {
    public let index: Int
    public let startSample: Int
    public let samples: [Float]
}

/// Bölümleyicinin parçalar arasında taşınan durumu.
public struct SegmenterState: Sendable, Equatable {
    /// Çerçeve olarak işlenmiş toplam örnek sayısı (`carry` hariç).
    public let consumedSamples: Int
    /// Bir sonraki açılacak bölümün sıra numarası.
    public let nextIndex: Int
    public let open: OpenSegment?
    /// Tam çerçeveye tamamlanmamış artık örnekler.
    public let carry: [Float]

    public static let initial: SegmenterState = SegmenterState(consumedSamples: 0, nextIndex: 0, open: nil, carry: [])
}

/// Bir bölümleme adımının sonucu.
public struct SegmenterOutput: Sendable, Equatable {
    public let state: SegmenterState
    public let closed: [ClosedSegment]
}

/// Yeni örnekleri çerçevelere bölüp konuşma bölümlerini çıkarır. Saf fonksiyondur.
///
/// Kurallar: RMS > eşik olan çerçeve konuşmadır. Açık bölüm yokken konuşma çerçevesi yeni bölüm açar,
/// sessiz çerçeve atılır. Sondaki sessizlik `minSilenceSec`'e ulaşınca bölüm sessizlik kırpılarak kapanır
/// (konuşma `minSpeechSec`'ten kısaysa atılır); bölüm `maxSegmentSec`'e ulaşınca kırpılmadan kapanır.
public func segmentAudio(state: SegmenterState, newSamples: [Float], config: SegmenterConfig) -> SegmenterOutput {
    let buffer: [Float] = state.carry + newSamples
    let frameCount: Int = buffer.count / config.frameSamples
    var consumed: Int = state.consumedSamples
    var nextIndex: Int = state.nextIndex
    var open: OpenSegment? = state.open
    var closed: [ClosedSegment] = []

    for frameNumber in 0..<frameCount {
        let frameStart: Int = frameNumber * config.frameSamples
        let frame: ArraySlice<Float> = buffer[frameStart..<(frameStart + config.frameSamples)]
        let step: FrameStep = advance(
            open: open,
            frame: frame,
            frameStartInStream: consumed,
            nextIndex: nextIndex,
            config: config
        )
        open = step.open
        nextIndex = step.nextIndex
        closed += step.closed
        consumed += config.frameSamples
    }

    let carry: [Float] = Array(buffer[(frameCount * config.frameSamples)...])
    return SegmenterOutput(
        state: SegmenterState(consumedSamples: consumed, nextIndex: nextIndex, open: open, carry: carry),
        closed: closed
    )
}

/// Açık bölümü sessizlik kuralıyla kapatır (oturum sonu). `carry` atılır.
public func flushSegmenter(state: SegmenterState, config: SegmenterConfig) -> SegmenterOutput {
    let closed: [ClosedSegment] = state.open.flatMap { (segment: OpenSegment) -> ClosedSegment? in
        closeTrimmingSilence(segment: segment, config: config)
    }.map { [$0] } ?? []
    return SegmenterOutput(
        state: SegmenterState(
            consumedSamples: state.consumedSamples + state.carry.count,
            nextIndex: state.nextIndex,
            open: nil,
            carry: []
        ),
        closed: closed
    )
}

/// Tek çerçevelik ilerlemenin sonucu.
private struct FrameStep {
    let open: OpenSegment?
    let nextIndex: Int
    let closed: [ClosedSegment]
}

/// Bir çerçeveyi açık bölüme uygular.
private func advance(
    open: OpenSegment?,
    frame: ArraySlice<Float>,
    frameStartInStream: Int,
    nextIndex: Int,
    config: SegmenterConfig
) -> FrameStep {
    let isSpeech: Bool = rootMeanSquare(frame: frame) > config.energyThreshold

    guard let current = open else {
        // Açık bölüm yok: yalnızca konuşma yeni bölüm açar.
        guard isSpeech else {
            return FrameStep(open: nil, nextIndex: nextIndex, closed: [])
        }
        let started: OpenSegment = OpenSegment(
            index: nextIndex,
            startSample: frameStartInStream,
            samples: Array(frame),
            trailingSilenceSamples: 0
        )
        return closeIfTooLong(segment: started, nextIndex: nextIndex + 1, config: config)
    }

    let grown: OpenSegment = OpenSegment(
        index: current.index,
        startSample: current.startSample,
        samples: current.samples + frame,
        trailingSilenceSamples: isSpeech ? 0 : current.trailingSilenceSamples + frame.count
    )

    let silenceLimit: Int = Int(config.minSilenceSec * Double(config.sampleRate))
    if grown.trailingSilenceSamples >= silenceLimit {
        let closed: [ClosedSegment] = closeTrimmingSilence(segment: grown, config: config).map { [$0] } ?? []
        return FrameStep(open: nil, nextIndex: nextIndex, closed: closed)
    }
    return closeIfTooLong(segment: grown, nextIndex: nextIndex, config: config)
}

/// Bölüm en fazla uzunluğa ulaştıysa kırpmadan kapatır.
private func closeIfTooLong(segment: OpenSegment, nextIndex: Int, config: SegmenterConfig) -> FrameStep {
    let maxSamples: Int = Int(config.maxSegmentSec * Double(config.sampleRate))
    guard segment.samples.count >= maxSamples else {
        return FrameStep(open: segment, nextIndex: nextIndex, closed: [])
    }
    let closed: ClosedSegment = ClosedSegment(index: segment.index, startSample: segment.startSample, samples: segment.samples)
    return FrameStep(open: nil, nextIndex: nextIndex, closed: [closed])
}

/// Sondaki sessizliği kırparak kapatır; kalan konuşma çok kısaysa nil döner.
private func closeTrimmingSilence(segment: OpenSegment, config: SegmenterConfig) -> ClosedSegment? {
    let speechCount: Int = segment.samples.count - segment.trailingSilenceSamples
    let minSpeech: Int = Int(config.minSpeechSec * Double(config.sampleRate))
    guard speechCount >= minSpeech else {
        return nil
    }
    return ClosedSegment(index: segment.index, startSample: segment.startSample, samples: Array(segment.samples[0..<speechCount]))
}

/// Çerçevenin karekök ortalama enerjisi.
private func rootMeanSquare(frame: ArraySlice<Float>) -> Float {
    guard !frame.isEmpty else {
        return 0
    }
    let sumOfSquares: Float = frame.reduce(0) { (partial: Float, sample: Float) -> Float in partial + sample * sample }
    return (sumOfSquares / Float(frame.count)).squareRoot()
}

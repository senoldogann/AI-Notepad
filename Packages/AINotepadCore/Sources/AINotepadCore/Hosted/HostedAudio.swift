import AVFoundation
import Foundation

/// Sunucunun tek istekte kabul ettiği en büyük ses (`TRANSCRIBE_MAX_BYTES`): 16 kHz mono 16 bit WAV'da ~49 dakika.
public let hostedTranscribeMaxBytes: Int = 95_000_000

/// Sunucuya gönderilen sesin örnekleme hızı. WAV'da süre başlıktan kesin hesaplanır (sıkıştırılmış ses en kötü bit
/// hızıyla tahmin edilip fazla ayrılır).
public let hostedTranscribeSampleRate: Int = 16000

/// Ardışık parçaların ortak süresi (saniye): parçanın son dakikası sonrakinin başında yeniden gönderilir; iki parçanın
/// aynı kelimelerine bakarak sonraki parçanın konuşmacıları öncekilerle eşlenir (ElevenLabs etiketleri parça içinde
/// anlamlıdır). Her parça sınırında bu kadar ses ikinci kez yazıya dökülür (sunucu toplantının ses hakkında bunun için
/// pay bırakır: sunucuda `chunkOverlapSeconds`).
public let hostedChunkOverlapSec: Double = 60

/// 16 bit mono WAV'ın başlık boyutu.
private let wavHeaderBytes: Int = 44

/// Kaydın bir WAV parçası: kaydın başından örnek konumu ve sayısı.
public struct WavChunkSpan: Sendable, Equatable {
    public let startSample: Int
    public let sampleCount: Int

    public init(startSample: Int, sampleCount: Int) {
        self.startSample = startSample
        self.sampleCount = sampleCount
    }

    /// Parçanın kaydın başından konumu (saniye).
    public func offsetSec(sampleRate: Int) -> Double {
        Double(startSample) / Double(sampleRate)
    }
}

/// `maxBytes`'lık bir 16 bit mono WAV'a sığan en çok örnek. Saf fonksiyondur.
public func maxSamplesPerWavChunk(maxBytes: Int) -> Int {
    (maxBytes - wavHeaderBytes) / 2
}

/// Toplam örneği en çok `maxSamples`'lık parçalara böler; her parça öncekinin son `overlapSamples` örneğiyle başlar
/// (`writeHostedWavChunks` ile aynı bölme). Son parça yalnızca ortak kısımdan ibaret olacaksa açılmaz; boş kayıtta parça
/// yok. Saf fonksiyondur.
public func wavChunkSpans(totalSamples: Int, maxSamples: Int, overlapSamples: Int) -> [WavChunkSpan] {
    let step: Int = maxSamples - overlapSamples
    var spans: [WavChunkSpan] = []
    var start: Int = 0
    while start < totalSamples {
        spans.append(WavChunkSpan(startSample: start, sampleCount: min(maxSamples, totalSamples - start)))
        guard start + maxSamples < totalSamples else {
            break
        }
        start += step
    }
    return spans
}

/// Bir parçanın konuşma tanıma sonucu, kaydın başından konumu ve önceki parçayla ortak süresi (ilk parçada 0).
public struct ChunkTranscription: Sendable, Equatable {
    public let offsetSec: Double
    public let overlapSec: Double
    public let result: DiarizationResult

    public init(offsetSec: Double, overlapSec: Double, result: DiarizationResult) {
        self.offsetSec = offsetSec
        self.overlapSec = overlapSec
        self.result = result
    }
}

/// Eşleme için ortak bölgede gereken en az ortak konuşma (saniye) ve oy payı: bir etiketin ortak konuşmasının en az
/// bu kadarı tek bir önceki etikete düşmeli.
private let overlapMatchMinSeconds: Double = 1.5
private let overlapMatchMinShare: Double = 0.6

/// Ortak bölgede sonraki parçanın etiketlerini önceki parçanın (kaydın genelindeki) etiketlerine eşler: aynı anda
/// söylenen kelimelerin süresi oy sayılır; en çok oydan başlanarak her iki taraf en fazla bir kez eşlenir, oyu az ya da
/// karışık etiket eşlenmez (yeni kişi kalır). Saf fonksiyondur.
public func overlapSpeakerMapping(previous: [DiarizedWord], current: [DiarizedWord]) -> [String: String] {
    var votes: [String: [String: Double]] = [:]
    for word in current {
        for earlier in previous {
            let shared: Double = min(word.endSec, earlier.endSec) - max(word.startSec, earlier.startSec)
            if shared > 0 {
                votes[word.speaker, default: [:]][earlier.speaker, default: 0] += shared
            }
        }
    }
    let ranked: [(current: String, previous: String, seconds: Double, share: Double)] = votes.flatMap {
        (entry: (key: String, value: [String: Double])) -> [(current: String, previous: String, seconds: Double, share: Double)] in
        let total: Double = entry.value.values.reduce(0, +)
        return entry.value.map { (current: entry.key, previous: $0.key, seconds: $0.value, share: total > 0 ? $0.value / total : 0) }
    }
    .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : ($0.current, $0.previous) < ($1.current, $1.previous) }
    var mapping: [String: String] = [:]
    for candidate in ranked where candidate.seconds >= overlapMatchMinSeconds && candidate.share >= overlapMatchMinShare {
        if mapping[candidate.current] == nil, !mapping.values.contains(candidate.previous) {
            mapping[candidate.current] = candidate.previous
        }
    }
    return mapping
}

/// Parça sonuçlarını kaydın tamamının sonucu yapar: kelime zamanları parçanın konumu kadar kaydırılır. Ortak bölgede
/// sonraki parçanın konuşmacıları öncekilerle eşlenir (`overlapSpeakerMapping`); eşlenemeyen etiket parça numarasıyla
/// ayrılır (`"2:speaker_0"`, ilk parça etiketini aynen korur). Ortak bölgenin ilk yarısının kelimeleri önceki, ikinci
/// yarısınınki sonraki parçadan alınır (kelime iki kez yazılmaz). Dil, olasılığı en yüksek parçanınkidir. Saf
/// fonksiyondur.
public func mergeChunkTranscriptions(chunks: [ChunkTranscription]) -> DiarizationResult {
    var words: [DiarizedWord] = []
    for (index, chunk) in chunks.enumerated() {
        let shifted: [DiarizedWord] = chunk.result.words.map { (word: DiarizedWord) -> DiarizedWord in
            DiarizedWord(text: word.text, startSec: word.startSec + chunk.offsetSec, endSec: word.endSec + chunk.offsetSec, speaker: word.speaker)
        }
        guard index > 0 else {
            words = shifted
            continue
        }
        let overlapEnd: Double = chunk.offsetSec + chunk.overlapSec
        let mapping: [String: String] = overlapSpeakerMapping(
            previous: words.filter { $0.endSec > chunk.offsetSec },
            current: shifted.filter { $0.startSec < overlapEnd }
        )
        let cut: Double = chunk.offsetSec + chunk.overlapSec / 2
        let relabeled: [DiarizedWord] = shifted.filter { $0.startSec >= cut }.map { (word: DiarizedWord) -> DiarizedWord in
            DiarizedWord(text: word.text, startSec: word.startSec, endSec: word.endSec, speaker: mapping[word.speaker] ?? "\(index + 1):\(word.speaker)")
        }
        words = words.filter { $0.startSec < cut } + relabeled
    }
    let language: DiarizationResult? = chunks.map(\.result)
        .filter { $0.languageCode != nil }
        .max { ($0.languageProbability ?? 0) < ($1.languageProbability ?? 0) }
    return DiarizationResult(words: words, languageCode: language?.languageCode, languageProbability: language?.languageProbability)
}

/// Diske yazılmış WAV parçası.
public struct WavChunkFile: Sendable, Equatable {
    public let url: URL
    public let span: WavChunkSpan
}

/// Sunucuya gönderilebilecek anahtar terimler: kırpılır, 1–49 karakter, en çok 5 kelime, `<>{}[]\` içermeyen,
/// tekrarsız ilk `limit` terim (sunucu geçersiz terimde tüm isteği reddeder). Saf fonksiyondur.
public func hostedKeyterms(terms: [String], limit: Int) -> [String] {
    let forbidden: Set<Character> = ["<", ">", "{", "}", "[", "]", "\\"]
    var seen: Set<String> = []
    return terms
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { (term: String) -> Bool in
            !term.isEmpty && term.count <= 49 && !term.contains(where: forbidden.contains)
                && term.split(whereSeparator: \.isWhitespace).count <= 5
        }
        .filter { seen.insert($0.lowercased()).inserted }
        .prefix(limit)
        .map { $0 }
}

/// Kayıt dosyasını (ör. `others.m4a`) 16 kHz mono 16 bit WAV parçalarına çevirip `directory`'ye yazar; her parça en
/// çok `maxBytes` ve öncekinin son `overlapSamples` örneğiyle başlar (bkz. `wavChunkSpans`). Dosya bellekte bütün olarak tutulmaz: akış halinde dönüştürülüp yazılır (4 saatlik toplantı ~460 MB
/// WAV eder). Dönüştürme ya da yazma hatasında yazılan parçalar `directory`'de kalır; çağıran klasörü siler.
public func writeHostedWavChunks(source: URL, directory: URL, maxBytes: Int, overlapSamples: Int) throws -> [WavChunkFile] {
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: source)
    } catch {
        throw StorageError.readFailed(path: source.path, reason: error.localizedDescription)
    }
    guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(hostedTranscribeSampleRate), channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: file.processingFormat, to: output) else {
        throw AudioCaptureError.converterCreationFailed(inputDescription: file.processingFormat.description)
    }
    // Çok kanallı girişte kanalların ortalaması.
    converter.downmix = true
    let inputCapacity: AVAudioFrameCount = 65_536
    let outputCapacity: AVAudioFrameCount = AVAudioFrameCount(hostedTranscribeSampleRate * 4)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inputCapacity) else {
        throw AudioCaptureError.conversionFailed(reason: "giriş tamponu oluşturulamadı")
    }
    var writer: WavChunkWriter = WavChunkWriter(directory: directory, maxSamples: maxSamplesPerWavChunk(maxBytes: maxBytes), overlapSamples: overlapSamples)
    var reachedEnd: Bool = false
    var readError: (any Error)?
    while true {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outputCapacity) else {
            throw AudioCaptureError.conversionFailed(reason: "çıkış tamponu oluşturulamadı")
        }
        var conversionError: NSError?
        let status: AVAudioConverterOutputStatus = converter.convert(to: buffer, error: &conversionError) { (_: AVAudioPacketCount, inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? in
            // Dosyanın sonunda `read` boş tampon yerine hata fırlatır: sona gelindiyse okunmaz.
            if reachedEnd || file.framePosition >= file.length {
                reachedEnd = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: inputCapacity)
            } catch {
                readError = error
                reachedEnd = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            if input.frameLength == 0 {
                reachedEnd = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        if let readError {
            throw StorageError.readFailed(path: source.path, reason: readError.localizedDescription)
        }
        if status == .error {
            throw AudioCaptureError.conversionFailed(reason: conversionError.map { String(describing: $0) } ?? "bilinmeyen hata")
        }
        if let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 {
            try writer.append(samples: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        }
        if status == .endOfStream {
            break
        }
    }
    return try writer.finish()
}

/// WAV parçalarını sırayla yazar: parça dolunca başlığı (veri boyutuyla) yazıp yenisine geçer; yeni parça öncekinin
/// son `overlapSamples` örneğiyle başlar (yalnızca yeni örnek gelirse açılır).
private struct WavChunkWriter {
    let directory: URL
    let maxSamples: Int
    let overlapSamples: Int
    private var finished: [WavChunkFile] = []
    private var handle: FileHandle?
    private var currentURL: URL?
    private var currentStart: Int = 0
    private var currentCount: Int = 0
    /// Açık parçanın son `overlapSamples` örneği (sonraki parçanın başı).
    private var tail: [Int16] = []

    init(directory: URL, maxSamples: Int, overlapSamples: Int) {
        self.directory = directory
        self.maxSamples = maxSamples
        self.overlapSamples = overlapSamples
    }

    /// Örnekleri parçalara yazar; parça sınırında böler.
    mutating func append(samples: UnsafeBufferPointer<Int16>) throws {
        var index: Int = 0
        while index < samples.count {
            if handle == nil {
                try open()
            }
            let take: Int = min(maxSamples - currentCount, samples.count - index)
            let slice: UnsafeBufferPointer<Int16> = UnsafeBufferPointer(rebasing: samples[index..<(index + take)])
            // Örnekler bellekte little-endian (Apple silikon ve Intel): WAV'ın bayt düzeniyle aynı.
            try write(data: Data(buffer: slice))
            tail = Array((tail + slice).suffix(overlapSamples))
            currentCount += take
            index += take
            if currentCount == maxSamples {
                try close()
            }
        }
    }

    /// Açık parçayı kapatır ve tüm parçaları döndürür.
    mutating func finish() throws -> [WavChunkFile] {
        if handle != nil {
            try close()
        }
        return finished
    }

    private mutating func open() throws {
        let url: URL = directory.appending(path: "chunk-\(finished.count).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: wavHeader(dataBytes: 0, sampleRate: hostedTranscribeSampleRate)) else {
            throw StorageError.writeFailed(path: url.path, reason: "dosya oluşturulamadı")
        }
        do {
            let opened: FileHandle = try FileHandle(forWritingTo: url)
            try opened.seekToEnd()
            handle = opened
        } catch {
            throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
        currentURL = url
        // Önceki parçanın sonu bu parçanın başına (ortak bölge).
        let carried: [Int16] = tail
        currentStart -= carried.count
        currentCount = carried.count
        if !carried.isEmpty {
            try carried.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<Int16>) -> Void in
                try write(data: Data(buffer: buffer))
            }
        }
    }

    private func write(data: Data) throws {
        guard let handle, let currentURL else {
            throw StorageError.writeFailed(path: directory.path, reason: "açık WAV parçası yok")
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw StorageError.writeFailed(path: currentURL.path, reason: error.localizedDescription)
        }
    }

    /// Başlığı gerçek veri boyutuyla yeniden yazar ve parçayı kapatır.
    private mutating func close() throws {
        guard let handle, let currentURL else {
            throw StorageError.writeFailed(path: directory.path, reason: "kapatılacak WAV parçası yok")
        }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: wavHeader(dataBytes: currentCount * 2, sampleRate: hostedTranscribeSampleRate))
            try handle.close()
        } catch {
            throw StorageError.writeFailed(path: currentURL.path, reason: error.localizedDescription)
        }
        finished.append(WavChunkFile(url: currentURL, span: WavChunkSpan(startSample: currentStart, sampleCount: currentCount)))
        currentStart += currentCount
        self.handle = nil
        self.currentURL = nil
        currentCount = 0
    }
}

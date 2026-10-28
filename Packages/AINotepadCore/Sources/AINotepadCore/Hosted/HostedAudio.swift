import AVFoundation
import Foundation

/// Sunucunun tek istekte kabul ettiği en büyük ses (`TRANSCRIBE_MAX_BYTES`): 16 kHz mono 16 bit WAV'da ~49 dakika.
public let hostedTranscribeMaxBytes: Int = 95_000_000

/// Sunucuya gönderilen sesin örnekleme hızı. WAV'da süre başlıktan kesin hesaplanır (sıkıştırılmış ses en kötü bit
/// hızıyla tahmin edilip fazla ayrılır).
public let hostedTranscribeSampleRate: Int = 16000

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

/// Toplam örneği en çok `maxSamples`'lık ardışık parçalara böler; boş kayıtta parça yok. Saf fonksiyondur.
public func wavChunkSpans(totalSamples: Int, maxSamples: Int) -> [WavChunkSpan] {
    stride(from: 0, to: totalSamples, by: maxSamples).map { (start: Int) -> WavChunkSpan in
        WavChunkSpan(startSample: start, sampleCount: min(maxSamples, totalSamples - start))
    }
}

/// Bir parçanın konuşma tanıma sonucu ve kaydın başından konumu.
public struct ChunkTranscription: Sendable, Equatable {
    public let offsetSec: Double
    public let result: DiarizationResult

    public init(offsetSec: Double, result: DiarizationResult) {
        self.offsetSec = offsetSec
        self.result = result
    }
}

/// Parça sonuçlarını kaydın tamamının sonucu yapar: kelime zamanları parçanın konumu kadar kaydırılır; konuşmacı
/// etiketleri yalnızca kendi parçasında anlamlı olduğu için parça numarasıyla ayrılır (`"2:speaker_0"`, ilk parça
/// etiketini aynen korur). Dil, olasılığı en yüksek parçanınkidir. Saf fonksiyondur.
public func mergeChunkTranscriptions(chunks: [ChunkTranscription]) -> DiarizationResult {
    let words: [DiarizedWord] = chunks.enumerated().flatMap { (item: (offset: Int, element: ChunkTranscription)) -> [DiarizedWord] in
        item.element.result.words.map { (word: DiarizedWord) -> DiarizedWord in
            DiarizedWord(
                text: word.text,
                startSec: word.startSec + item.element.offsetSec,
                endSec: word.endSec + item.element.offsetSec,
                speaker: item.offset == 0 ? word.speaker : "\(item.offset + 1):\(word.speaker)"
            )
        }
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
/// çok `maxBytes`. Dosya bellekte bütün olarak tutulmaz: akış halinde dönüştürülüp yazılır (4 saatlik toplantı ~460 MB
/// WAV eder). Dönüştürme ya da yazma hatasında yazılan parçalar `directory`'de kalır; çağıran klasörü siler.
public func writeHostedWavChunks(source: URL, directory: URL, maxBytes: Int) throws -> [WavChunkFile] {
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
    var writer: WavChunkWriter = WavChunkWriter(directory: directory, maxSamples: maxSamplesPerWavChunk(maxBytes: maxBytes))
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

/// WAV parçalarını sırayla yazar: parça dolunca başlığı (veri boyutuyla) yazıp yenisine geçer.
private struct WavChunkWriter {
    let directory: URL
    let maxSamples: Int
    private var finished: [WavChunkFile] = []
    private var handle: FileHandle?
    private var currentURL: URL?
    private var currentStart: Int = 0
    private var currentCount: Int = 0

    init(directory: URL, maxSamples: Int) {
        self.directory = directory
        self.maxSamples = maxSamples
    }

    /// Örnekleri parçalara yazar; parça sınırında böler.
    mutating func append(samples: UnsafeBufferPointer<Int16>) throws {
        var index: Int = 0
        while index < samples.count {
            if handle == nil {
                try open()
            }
            let take: Int = min(maxSamples - currentCount, samples.count - index)
            // Örnekler bellekte little-endian (Apple silikon ve Intel): WAV'ın bayt düzeniyle aynı.
            try write(data: Data(buffer: UnsafeBufferPointer(rebasing: samples[index..<(index + take)])))
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
        currentCount = 0
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

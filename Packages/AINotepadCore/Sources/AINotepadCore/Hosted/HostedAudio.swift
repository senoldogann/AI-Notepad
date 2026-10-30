import AVFoundation
import Foundation

/// Sunucunun tek istekte kabul ettiği en büyük ses (`TRANSCRIBE_MAX_BYTES`, Cloudflare'ın 100 MB istek gövdesi
/// sınırının altında): 16 kHz mono 16 bit WAV'da ~49 dakika; FLAC'ta içeriğe bağlı (konuşmada yaklaşık iki katı).
public let hostedTranscribeMaxBytes: Int = 95_000_000

/// Sunucuya gönderilen sesin örnekleme hızı. Ses kayıpsız FLAC olarak gider; sunucu süreyi STREAMINFO'daki örnek
/// sayısından kesin hesaplar (WAV'da başlıktan).
public let hostedTranscribeSampleRate: Int = 16000

/// FLAC parçasının en uzun süresi (saniye; boyut sınırı `hostedTranscribeMaxBytes` ayrıca uygulanır). Sunucunun
/// ElevenLabs bekleme süresi (15 dk) ve ses ayırmasının ömrü (20 dk) 95 MB'lık ~49 dakikalık WAV parçasına göre
/// ayarlıdır; işlem süresi ses süresiyle arttığı için parça bu pencereler değişmeden en çok 60 dk olur (FLAC yüklemesi
/// WAV'ınkinin yaklaşık yarısıdır). İstemci zaman aşımı 60 dakikalık parçada da 16 dk alt sınırındadır
/// (`hostedTranscribeTimeoutSec`: 300 + 60 × 10 = 900 sn < 960 sn). Bir saatlik toplantı tek parçada gider.
public let hostedFlacChunkMaxSec: Double = 3600

/// Ardışık parçaların ortak süresi (saniye): parçanın son dakikası sonrakinin başında yeniden gönderilir; iki parçanın
/// aynı kelimelerine bakarak sonraki parçanın konuşmacıları öncekilerle eşlenir (ElevenLabs etiketleri parça içinde
/// anlamlıdır). Her parça sınırında bu kadar ses ikinci kez yazıya dökülür (sunucu toplantının ses hakkında bunun için
/// pay bırakır: sunucuda `chunkOverlapSeconds`).
public let hostedChunkOverlapSec: Double = 60

/// 16 bit mono WAV'ın başlık boyutu.
private let wavHeaderBytes: Int = 44

/// Kaydın bir parçası: kaydın başından örnek konumu ve sayısı.
public struct AudioChunkSpan: Sendable, Equatable {
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
/// (`writeHostedFlacChunks` ile aynı bölme). Son parça yalnızca ortak kısımdan ibaret olacaksa açılmaz; boş kayıtta parça
/// yok. WAV sınırıyla (`maxSamplesPerWavChunk`) yapılan bölme, sunucunun parça örtüşmesi payının dayandığı en kısa
/// parçalamadır (yayımlanmış WAV gönderen sürümler). Saf fonksiyondur.
public func wavChunkSpans(totalSamples: Int, maxSamples: Int, overlapSamples: Int) -> [AudioChunkSpan] {
    let step: Int = maxSamples - overlapSamples
    var spans: [AudioChunkSpan] = []
    var start: Int = 0
    while start < totalSamples {
        spans.append(AudioChunkSpan(startSample: start, sampleCount: min(maxSamples, totalSamples - start)))
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

/// Diske yazılmış FLAC parçası: kayıttaki konumu ve dosya boyutu (bayt).
public struct AudioChunkFile: Sendable, Equatable {
    public let url: URL
    public let span: AudioChunkSpan
    public let bytes: Int
}

/// Sunucuya gönderilebilecek anahtar terimler: kırpılır, 1–49 UTF-16 birimi (sunucudaki JS `length` gibi; emoji iki
/// birim sayılır), en çok 5 kelime, `<>{}[]\` içermeyen, tekrarsız ilk `limit` terim (sunucu geçersiz terimde tüm isteği
/// reddeder). Saf fonksiyondur.
public func hostedKeyterms(terms: [String], limit: Int) -> [String] {
    let forbidden: Set<Character> = ["<", ">", "{", "}", "[", "]", "\\"]
    var seen: Set<String> = []
    return terms
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { (term: String) -> Bool in
            !term.isEmpty && term.utf16.count <= 49 && !term.contains(where: forbidden.contains)
                && term.split(whereSeparator: \.isWhitespace).count <= 5
        }
        .filter { seen.insert($0.lowercased()).inserted }
        .prefix(limit)
        .map { $0 }
}

/// FLAC dosyasının başındaki STREAMINFO bloğunun alanları.
public struct FlacStreamInfo: Sendable, Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let totalSamples: Int

    public init(sampleRate: Int, channels: Int, bitsPerSample: Int, totalSamples: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.totalSamples = totalSamples
    }
}

/// STREAMINFO'yu okumak için gereken baştaki bayt: `fLaC` (4) + blok başlığı (4) + STREAMINFO (34).
public let flacStreamInfoHeaderBytes: Int = 42

/// FLAC'ın başını okur: `fLaC` imzası ve ilk metadata bloğu 34 baytlık STREAMINFO olmalı (sunucu da aynısını ister).
/// Blok verisinin 10. baytından itibaren: 20 bit örnekleme hızı, 3 bit kanal − 1, 5 bit örnek biti − 1, 36 bit toplam
/// örnek (büyük uçlu). Saf fonksiyondur.
public func flacStreamInfo(header: Data) throws -> FlacStreamInfo {
    let bytes: [UInt8] = Array(header.prefix(flacStreamInfoHeaderBytes))
    guard bytes.count == flacStreamInfoHeaderBytes, bytes[0..<4].elementsEqual(Array("fLaC".utf8)) else {
        throw AudioCaptureError.conversionFailed(reason: "FLAC imzası yok ya da başlık kısa (\(bytes.count) bayt)")
    }
    // Blok başlığının ilk biti "son blok" işaretidir; kalan 7 bit tür (0 = STREAMINFO), sonraki 3 bayt uzunluk.
    guard bytes[4] & 0x7F == 0, bytes[5..<8].elementsEqual([0, 0, 34]) else {
        throw AudioCaptureError.conversionFailed(reason: "FLAC'ın ilk metadata bloğu STREAMINFO değil")
    }
    let sampleRate: Int = Int(bytes[18]) << 12 | Int(bytes[19]) << 4 | Int(bytes[20] >> 4)
    let channels: Int = Int((bytes[20] >> 1) & 0x07) + 1
    let bitsPerSample: Int = (Int(bytes[20] & 0x01) << 4 | Int(bytes[21] >> 4)) + 1
    let totalSamples: Int = Int(bytes[21] & 0x0F) << 32 | Int(bytes[22]) << 24 | Int(bytes[23]) << 16 | Int(bytes[24]) << 8 | Int(bytes[25])
    return FlacStreamInfo(sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample, totalSamples: totalSamples)
}

/// Sınırı aşan FLAC parçasının yeniden kodlanacak örnek sayısı: FLAC boyutu örnek sayısıyla yaklaşık doğrusal
/// olduğundan aşım oranında kısaltılır ve %1 pay bırakılır (sıkıştırma parça içinde değişir); pay yetmezse çağıran bir
/// kez daha kısaltır. Kısalan parça ortak bölgeden uzun olmalı (yoksa kayıt ilerlemez); değilse hata. Saf fonksiyondur.
public func shortenedFlacSampleCount(sampleCount: Int, encodedBytes: Int, maxBytes: Int, overlapSamples: Int) throws -> Int {
    let shorter: Int = Int(Double(sampleCount) * Double(maxBytes) / Double(encodedBytes) * 0.99)
    guard shorter > overlapSamples, shorter < sampleCount else {
        throw AudioCaptureError.conversionFailed(reason: "FLAC parçası \(maxBytes) bayta sığmıyor: \(sampleCount) örnek \(encodedBytes) bayt")
    }
    return shorter
}

/// Kayıt dosyasını (ör. `others.m4a`) 16 kHz mono 16 bit örneklere çevirip kayıpsız FLAC parçaları olarak
/// `directory`'ye yazar: her parça en çok `maxSamples` örnek ve en çok `maxBytes` bayt, öncekinin son `overlapSamples`
/// örneğiyle başlar; son parça yalnızca ortak kısımdan ibaret olacaksa açılmaz (`wavChunkSpans` ile aynı bölme).
///
/// FLAC'ın boyutu içeriğe bağlıdır (konuşmada PCM'in yaklaşık yarısı, beyaz gürültüde PCM'den ~%0,1 büyük); güvenli bir
/// sabit üst sınır WAV'dan uzun parça vermezdi. Bu yüzden parça önce `maxSamples` ile kodlanıp boyutu ölçülür;
/// `maxBytes`'ı aşarsa aynı başlangıçtan kısaltılarak yeniden kodlanır (`shortenedFlacSampleCount`). Örnekler önce
/// `directory`'deki ham PCM dosyasına akış halinde yazılır (dosya bellekte bütün olarak tutulmaz; 4 saatlik toplantı
/// ~460 MB eder), parçalar oradan kodlanır; ham dosya iş bitince silinir. Hata durumunda yazılanlar `directory`'de
/// kalır; çağıran klasörü siler.
public func writeHostedFlacChunks(source: URL, directory: URL, maxBytes: Int, maxSamples: Int, overlapSamples: Int) throws -> [AudioChunkFile] {
    let pcmURL: URL = directory.appending(path: "samples.pcm")
    let totalSamples: Int = try writeHostedPcm(source: source, destination: pcmURL)
    let pcm: FileHandle
    do {
        pcm = try FileHandle(forReadingFrom: pcmURL)
    } catch {
        throw StorageError.readFailed(path: pcmURL.path, reason: error.localizedDescription)
    }
    var chunks: [AudioChunkFile] = []
    var start: Int = 0
    while start < totalSamples {
        let url: URL = directory.appending(path: "chunk-\(chunks.count).flac")
        var count: Int = min(maxSamples, totalSamples - start)
        var bytes: Int = try encodeFlacChunk(pcm: pcm, pcmPath: pcmURL.path, startSample: start, sampleCount: count, destination: url)
        while bytes > maxBytes {
            count = try shortenedFlacSampleCount(sampleCount: count, encodedBytes: bytes, maxBytes: maxBytes, overlapSamples: overlapSamples)
            bytes = try encodeFlacChunk(pcm: pcm, pcmPath: pcmURL.path, startSample: start, sampleCount: count, destination: url)
        }
        chunks.append(AudioChunkFile(url: url, span: AudioChunkSpan(startSample: start, sampleCount: count), bytes: bytes))
        guard start + count < totalSamples else {
            break
        }
        start += count - overlapSamples
    }
    do {
        try pcm.close()
        try FileManager.default.removeItem(at: pcmURL)
    } catch {
        throw StorageError.deleteFailed(path: pcmURL.path, reason: error.localizedDescription)
    }
    return chunks
}

/// Kayıt dosyasını 16 kHz mono 16 bit ham PCM (küçük uçlu, başlıksız) olarak `destination`'a akış halinde yazar ve
/// örnek sayısını döndürür. Çok kanallı girişte kanalların ortalaması alınır.
private func writeHostedPcm(source: URL, destination: URL) throws -> Int {
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
    converter.downmix = true
    let inputCapacity: AVAudioFrameCount = 65_536
    let outputCapacity: AVAudioFrameCount = AVAudioFrameCount(hostedTranscribeSampleRate * 4)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inputCapacity) else {
        throw AudioCaptureError.conversionFailed(reason: "giriş tamponu oluşturulamadı")
    }
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
        throw StorageError.writeFailed(path: destination.path, reason: "dosya oluşturulamadı")
    }
    let handle: FileHandle
    do {
        handle = try FileHandle(forWritingTo: destination)
    } catch {
        throw StorageError.writeFailed(path: destination.path, reason: error.localizedDescription)
    }
    var totalSamples: Int = 0
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
            // Örnekler bellekte küçük uçlu (Apple silikon ve Intel); dosya aynı cihazda geri okunur.
            do {
                try handle.write(contentsOf: Data(buffer: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
            } catch {
                throw StorageError.writeFailed(path: destination.path, reason: error.localizedDescription)
            }
            totalSamples += Int(buffer.frameLength)
        }
        if status == .endOfStream {
            break
        }
    }
    do {
        try handle.close()
    } catch {
        throw StorageError.writeFailed(path: destination.path, reason: error.localizedDescription)
    }
    return totalSamples
}

/// Apple'ın yerleşik FLAC kodlayıcısının ayarları (macOS ve iOS): 16 kHz mono, 16 bit örnek. Kodlayıcı dosya
/// kapanınca STREAMINFO'ya gerçek örnek sayısını yazar; `encodeFlacChunk` bunu doğrular.
private let hostedFlacSettings: [String: Int] = [
    AVFormatIDKey: Int(kAudioFormatFLAC),
    AVSampleRateKey: hostedTranscribeSampleRate,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
]

/// Ham PCM dosyasının `startSample`'dan başlayan `sampleCount` örneğini `destination`'a FLAC olarak yazar (varsa
/// üzerine) ve dosyanın bayt boyutunu döndürür. Kapanıştan sonra STREAMINFO okunur: örnek sayısı, hız, kanal ya da bit
/// beklenenden farklıysa hata (sunucu süreyi oradan hesaplar).
private func encodeFlacChunk(pcm: FileHandle, pcmPath: String, startSample: Int, sampleCount: Int, destination: URL) throws -> Int {
    if FileManager.default.fileExists(atPath: destination.path) {
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            throw StorageError.deleteFailed(path: destination.path, reason: error.localizedDescription)
        }
    }
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forWriting: destination, settings: hostedFlacSettings, commonFormat: .pcmFormatInt16, interleaved: true)
    } catch {
        throw StorageError.writeFailed(path: destination.path, reason: error.localizedDescription)
    }
    let blockSamples: Int = 65_536
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(blockSamples)),
          let samples = buffer.int16ChannelData?[0] else {
        throw AudioCaptureError.conversionFailed(reason: "FLAC tamponu oluşturulamadı")
    }
    do {
        try pcm.seek(toOffset: UInt64(startSample * 2))
    } catch {
        throw StorageError.readFailed(path: pcmPath, reason: error.localizedDescription)
    }
    var written: Int = 0
    while written < sampleCount {
        let take: Int = min(blockSamples, sampleCount - written)
        let data: Data
        do {
            data = try pcm.read(upToCount: take * 2) ?? Data()
        } catch {
            throw StorageError.readFailed(path: pcmPath, reason: error.localizedDescription)
        }
        guard data.count == take * 2 else {
            throw StorageError.readFailed(path: pcmPath, reason: "PCM dosyası beklenenden kısa (\(startSample + written). örnekten sonra \(data.count) bayt)")
        }
        _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: samples, count: take))
        buffer.frameLength = AVAudioFrameCount(take)
        do {
            try file.write(from: buffer)
        } catch {
            throw StorageError.writeFailed(path: destination.path, reason: error.localizedDescription)
        }
        written += take
    }
    // Kapanışta kodlayıcı STREAMINFO'yu (örnek sayısı, MD5) dosyanın başına yazar.
    file.close()
    let header: Data
    let bytes: Int
    do {
        let reader: FileHandle = try FileHandle(forReadingFrom: destination)
        header = try reader.read(upToCount: flacStreamInfoHeaderBytes) ?? Data()
        bytes = Int(try reader.seekToEnd())
        try reader.close()
    } catch {
        throw StorageError.readFailed(path: destination.path, reason: error.localizedDescription)
    }
    let info: FlacStreamInfo = try flacStreamInfo(header: header)
    let expected: FlacStreamInfo = FlacStreamInfo(sampleRate: hostedTranscribeSampleRate, channels: 1, bitsPerSample: 16, totalSamples: sampleCount)
    guard info == expected else {
        throw AudioCaptureError.conversionFailed(reason: "FLAC STREAMINFO beklenenden farklı: \(String(describing: info)), beklenen: \(String(describing: expected))")
    }
    return bytes
}


import Foundation
import os

/// Akış tabanlı yazıya dökme olayları; zamanlar akışın başından itibaren saniye.
public enum StreamingEvent: Sendable, Equatable {
    case partial(text: String, startSec: Double, endSec: Double)
    case final(text: String, startSec: Double, endSec: Double)
    /// Akış kalıcı olarak durdu; bundan sonra olay gelmez.
    case failed(message: String)
}

/// Deepgram'ın bağlantı başına sıfırdan başlayan zamanını akışın mutlak zamanına çevirir.
public func absoluteTime(deepgramSec: Double, connectionStartSample: Int, sampleRate: Int) -> Double {
    Double(connectionStartSample) / Double(sampleRate) + deepgramSec
}

/// Çalışan bir Deepgram akışı: olaylar ve dil değiştirme.
public struct DeepgramStream: Sendable {
    public let events: AsyncStream<StreamingEvent>
    fileprivate let connection: DeepgramConnection

    /// Akışı yeni dille yeniden bağlar; zaman çizelgesi kesintisiz devam eder.
    public func switchLanguage(to language: MeetingLanguage) async {
        await connection.switchLanguage(to: language)
    }
}

/// Sesi Deepgram'a canlı akıtır ve geçici/kesin metin olaylarını yayınlar.
///
/// Bağlantı beklenmedik koparsa 4 kez geri çekilmeli yeniden bağlanır; kopukken gelen ses tamponda
/// bekler ve bağlanınca gönderilir. Geçersiz anahtar gibi 4xx el sıkışma hataları yeniden denenmez.
/// Ses akışı bitince `CloseStream` gönderilir, kalan sonuçlar alınır ve olay akışı biter.
public func startDeepgramStream(apiKey: String, language: MeetingLanguage, audio: AsyncStream<[Float]>) -> DeepgramStream {
    let (events, sink): (AsyncStream<StreamingEvent>, AsyncStream<StreamingEvent>.Continuation) =
        AsyncStream.makeStream(of: StreamingEvent.self)
    let connection: DeepgramConnection = DeepgramConnection(
        apiKey: apiKey,
        url: deepgramListenURL(language: language),
        events: sink
    )
    Task {
        await connection.run(audio: audio)
    }
    return DeepgramStream(events: events, connection: connection)
}

private let deepgramLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Deepgram")
private let deepgramSampleRate: Int = 16000

/// Tek bir Deepgram akışının bağlantı durumu.
private actor DeepgramConnection {
    private let apiKey: String
    /// İstenen dilin adresi; dil değişince güncellenir.
    private var url: URL
    /// Geçerli bağlantının kurulduğu adres.
    private var connectedURL: URL?
    private let events: AsyncStream<StreamingEvent>.Continuation
    private let session: URLSession = URLSession(configuration: .default)

    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    /// Bağlantı yokken ya da gönderilmeyi beklerken biriken ses.
    private var pending: [Float] = []
    /// Bugüne kadar başarıyla gönderilen örnek sayısı.
    private var samplesSent: Int = 0
    /// Geçerli bağlantının başladığı örnek (Deepgram zamanı buradan sıfırlanır).
    private var connectionStartSample: Int = 0
    private var isConnected: Bool = false
    private var isReconnecting: Bool = false
    private var isClosing: Bool = false
    private var hasFailed: Bool = false

    init(apiKey: String, url: URL, events: AsyncStream<StreamingEvent>.Continuation) {
        self.apiKey = apiKey
        self.url = url
        self.events = events
    }

    func run(audio: AsyncStream<[Float]>) async {
        do {
            try await connectWithRetry()
            await reconnectIfLanguageChanged()
        } catch {
            fail(error: error)
        }
        for await chunk in audio {
            // Kalıcı hatadan sonra da akış tüketilir ki üretici tarafta ses birikmesin.
            guard !hasFailed else {
                continue
            }
            pending += chunk
            if isConnected {
                await flush()
            }
        }
        await close()
    }

    /// Bağlanır ve el sıkışmanın bittiğini ping ile doğrular.
    private func connect() async throws {
        var request: URLRequest = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let task: URLSessionWebSocketTask = session.webSocketTask(with: request)
        task.resume()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) -> Void in
                task.sendPing { (error: (any Error)?) -> Void in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            if let status = (task.response as? HTTPURLResponse)?.statusCode {
                throw CloudSTTError.http(service: "deepgram", status: status, body: "")
            }
            throw CloudSTTError.connectionFailed(service: "deepgram", reason: String(describing: error))
        }
        socket = task
        connectedURL = request.url
        connectionStartSample = samplesSent
        isConnected = true
        receiver = Task { await self.receiveLoop(task: task) }
        deepgramLogger.info("Deepgram bağlandı, başlangıç örneği: \(self.connectionStartSample, privacy: .public)")
    }

    /// 4 kez geri çekilmeli bağlanmayı dener. 4xx yanıtı (ör. geçersiz anahtar) yeniden denenmez.
    private func connectWithRetry() async throws {
        var rejection: CloudSTTError?
        try await retryWithBackoff(
            attempts: 4,
            delaySec: 0.25,
            isolation: self,
            operation: {
                do {
                    try await self.connect()
                } catch CloudSTTError.http(let service, let status, let body) where (400..<500).contains(status) {
                    // Denemeyi bitir; reddi aşağıda fırlat.
                    rejection = CloudSTTError.http(service: service, status: status, body: body)
                }
            },
            onFailure: { (attempt: Int, failure: any Error) -> Void in
                deepgramLogger.warning("Deepgram'a bağlanılamadı, deneme \(attempt, privacy: .public): \(String(describing: failure), privacy: .public)")
            }
        )
        if let rejection {
            throw rejection
        }
    }

    /// Bekleyen sesi gönderir; gönderim başarısızsa ses tampona geri konur.
    private func flush() async {
        guard let socket, !pending.isEmpty else {
            return
        }
        let chunk: [Float] = pending
        pending = []
        do {
            try await socket.send(.data(linear16Data(samples: chunk)))
            samplesSent += chunk.count
        } catch {
            pending = chunk + pending
            await handleDisconnect(error: error)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // Kapanışta ya da dil değişiminde eski bağlantının hatası yok sayılır.
                guard !isClosing, task === socket else {
                    return
                }
                await handleDisconnect(error: error)
                return
            }
            // Eski bağlantıdan gecikmeli gelen sonuç yeni zaman çizelgesini bozmasın.
            guard task === socket else {
                return
            }
            handle(message: message)
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        do {
            guard case .results(let result) = try parseDeepgramMessage(data: data), !result.transcript.isEmpty else {
                return
            }
            let start: Double = absoluteTime(deepgramSec: result.startSec, connectionStartSample: connectionStartSample, sampleRate: deepgramSampleRate)
            let end: Double = absoluteTime(deepgramSec: result.endSec, connectionStartSample: connectionStartSample, sampleRate: deepgramSampleRate)
            events.yield(result.isFinal
                ? .final(text: result.transcript, startSec: start, endSec: end)
                : .partial(text: result.transcript, startSec: start, endSec: end))
        } catch {
            // Tek bozuk mesaj akışı durdurmaz; içerik hata ayıklama için loglanır.
            deepgramLogger.error("Deepgram mesajı ayrıştırılamadı: \(String(describing: error), privacy: .public)")
        }
    }

    /// Bağlantı koptu: geri çekilmeli yeniden bağlan, tamponu gönder; olmazsa kalıcı hata.
    private func handleDisconnect(error: any Error) async {
        guard isConnected, !isReconnecting, !isClosing, !hasFailed else {
            return
        }
        isConnected = false
        isReconnecting = true
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        deepgramLogger.warning("Deepgram bağlantısı koptu: \(String(describing: error), privacy: .public)")
        do {
            try await connectWithRetry()
            isReconnecting = false
            await reconnectIfLanguageChanged()
            await flush()
        } catch {
            isReconnecting = false
            fail(error: error)
        }
    }

    /// Dili değiştirir. Bağlıysa hemen yeni dille yeniden bağlanır; bağlantı kuruluyorsa
    /// kurulduktan sonra `reconnectIfLanguageChanged` yeni dile geçer.
    func switchLanguage(to language: MeetingLanguage) async {
        url = deepgramListenURL(language: language)
        guard isConnected, !isReconnecting else {
            return
        }
        await reconnectIfLanguageChanged()
    }

    /// Bağlantı istenen dilde değilse kapatıp yeni adresle bağlanır, sonra tamponu gönderir.
    private func reconnectIfLanguageChanged() async {
        guard isConnected, !hasFailed, connectedURL != url else {
            return
        }
        isConnected = false
        isReconnecting = true
        let old: URLSessionWebSocketTask? = socket
        socket = nil
        old?.cancel(with: .normalClosure, reason: nil)
        deepgramLogger.info("Deepgram dili değişiyor: \(self.url.absoluteString, privacy: .public)")
        do {
            try await connectWithRetry()
            isReconnecting = false
            await flush()
        } catch {
            isReconnecting = false
            fail(error: error)
        }
    }

    /// Ses bitti: kalanı gönder, `CloseStream` ile son sonuçları iste, en fazla 5 sn bekle.
    private func close() async {
        if isConnected {
            await flush()
        }
        guard let socket, !hasFailed else {
            events.finish()
            return
        }
        isClosing = true
        do {
            try await socket.send(.string(#"{"type":"CloseStream"}"#))
            let receiving: Task<Void, Never>? = receiver
            let timeout: Task<Void, Never> = Task {
                do {
                    try await Task.sleep(for: .seconds(5))
                    receiving?.cancel()
                } catch {
                    // Sonuçlar 5 sn dolmadan geldi; zamanlayıcı iptal edildi.
                }
            }
            await receiving?.value
            timeout.cancel()
        } catch {
            deepgramLogger.error("CloseStream gönderilemedi: \(String(describing: error), privacy: .public)")
        }
        socket.cancel(with: .normalClosure, reason: nil)
        events.finish()
    }

    /// Kalıcı hata: kullanıcıya gösterilecek mesajı yayınla ve akışı bitir.
    private func fail(error: any Error) {
        guard !hasFailed else {
            return
        }
        hasFailed = true
        isConnected = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        deepgramLogger.error("Deepgram akışı durdu: \(String(describing: error), privacy: .public)")
        events.yield(.failed(message: deepgramFailureMessage(error: error)))
        events.finish()
    }
}

/// Kullanıcıya gösterilecek Türkçe hata metni (anahtar içermez).
private func deepgramFailureMessage(error: any Error) -> String {
    switch error {
    case CloudSTTError.http(_, let status, _) where status == 401 || status == 403:
        return "Deepgram anahtarı geçersiz (HTTP \(status)). Ayarlar'dan kontrol et."
    case CloudSTTError.http(_, let status, _):
        return "Deepgram bağlantısı reddedildi (HTTP \(status))."
    case CloudSTTError.connectionFailed(_, let reason):
        return "Deepgram'a bağlanılamadı: \(reason)"
    default:
        return "Deepgram akışı durdu: \(String(describing: error))"
    }
}

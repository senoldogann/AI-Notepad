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

/// Deepgram sonucunu akış olayına çevirir. Boş geçici sonuç atılır; boş kesin sonuç geçer ki
/// ekrandaki geçici metin silinsin. Saf fonksiyondur.
public func streamingEvent(result: DeepgramResult, connectionStartSample: Int, sampleRate: Int) -> StreamingEvent? {
    let start: Double = absoluteTime(deepgramSec: result.startSec, connectionStartSample: connectionStartSample, sampleRate: sampleRate)
    let end: Double = absoluteTime(deepgramSec: result.endSec, connectionStartSample: connectionStartSample, sampleRate: sampleRate)
    if result.isFinal {
        return .final(text: result.transcript, startSec: start, endSec: end)
    }
    return result.transcript.isEmpty ? nil : .partial(text: result.transcript, startSec: start, endSec: end)
}

/// Yeniden bağlanma bekleme süreleri: `initialSec`'ten başlayıp ikiye katlanır, `capSec`'te sabitlenir;
/// toplamı `budgetSec`'e ulaşana kadar. Saf fonksiyondur.
public func reconnectDelays(budgetSec: Double, initialSec: Double, capSec: Double) -> [Double] {
    var delays: [Double] = []
    var next: Double = initialSec
    while delays.reduce(0, +) < budgetSec {
        delays.append(next)
        next = min(next * 2, capSec)
    }
    return delays
}

/// Çalışan bir Deepgram akışı: olaylar ve dil değiştirme.
public struct DeepgramStream: Sendable {
    public let events: AsyncStream<StreamingEvent>
    fileprivate let connection: DeepgramConnection

    /// Akışı yeni dille yeniden bağlar; zaman çizelgesi kesintisiz devam eder.
    public func switchLanguage(to language: MeetingLanguage) async {
        await connection.switchLanguage(to: language)
    }

    /// Yalnızca testler için: ağ kopmuş gibi geçerli bağlantıyı aniden kapatır.
    func dropConnectionForTesting() async {
        await connection.dropConnectionForTesting()
    }
}

/// Sesi Deepgram'a canlı akıtır ve geçici/kesin metin olaylarını yayınlar.
///
/// Bağlantı koparsa (ya da 20 sn hiç mesaj gelmezse) en fazla ~2 dk geri çekilmeli yeniden bağlanır;
/// kopukken gelen ses ve henüz kesinleşmemiş gönderilmiş ses bağlanınca yeniden gönderilir.
/// Geçersiz anahtar gibi 4xx el sıkışma hataları yeniden denenmez.
/// Ses akışı bitince `CloseStream` gönderilir, kalan sonuçlar alınır ve olay akışı biter.
public func startDeepgramStream(apiKey: String, language: MeetingLanguage, keyterms: [String], audio: AsyncStream<[Float]>) -> DeepgramStream {
    let (events, sink): (AsyncStream<StreamingEvent>, AsyncStream<StreamingEvent>.Continuation) =
        AsyncStream.makeStream(of: StreamingEvent.self)
    let connection: DeepgramConnection = DeepgramConnection(
        apiKey: apiKey,
        url: deepgramListenURL(language: language, keyterms: keyterms),
        keyterms: keyterms,
        events: sink
    )
    Task {
        await connection.run(audio: audio)
    }
    return DeepgramStream(events: events, connection: connection)
}

private let deepgramLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Deepgram")
private let deepgramSampleRate: Int = 16000

/// Yeniden bağlanma için toplam süre; ağ bu kadar süre gelmezse akış kalıcı olarak durur.
private let reconnectBudgetSec: Double = 120
/// Bu kadar süre hiç mesaj gelmezse bağlantı kopmuş sayılır (Deepgram sessizlikte de sonuç yollar).
private let silenceTimeoutSec: Double = 20
/// Kapanışta son sonuçlar için en fazla bekleme.
private let closeDeadlineSec: Double = 5

/// Tek bir Deepgram akışının bağlantı durumu.
private actor DeepgramConnection {
    private let apiKey: String
    private let events: AsyncStream<StreamingEvent>.Continuation
    private let session: URLSession = URLSession(configuration: .default)
    /// İstenen dilin adresi; dil değişince güncellenir.
    private var url: URL
    /// Geçerli bağlantının kurulduğu adres.
    private var connectedURL: URL?

    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastMessageAt: ContinuousClock.Instant = .now

    /// Henüz gönderilmemiş ses.
    private var pending: [Float] = []
    /// Şu an gönderilmekte olan parça; zaman sırası: unacknowledged → inFlight → pending.
    private var inFlight: [Float] = []
    /// Gönderilmiş ama kesin sonucu gelmemiş ses; kopmada yeniden gönderilir.
    private var unacknowledged: [Float] = []
    /// `unacknowledged`'ın akıştaki başlangıç örneği (= gönderilmiş ve onaylanmış ses sonu).
    private var acknowledgedSample: Int = 0
    /// Geçerli bağlantının başladığı örnek (Deepgram zamanı buradan sıfırlanır).
    private var connectionStartSample: Int = 0

    private var isConnected: Bool = false
    private var isReconnecting: Bool = false
    private var isFlushing: Bool = false
    private var isClosing: Bool = false
    /// Kapanış süresi doldu: yeniden bağlanma denemeleri bırakılır.
    private var closeDeadlinePassed: Bool = false
    private var hasFailed: Bool = false

    /// Adlar ve terimler; dil değişince yeni adrese de eklenir.
    private let keyterms: [String]

    init(apiKey: String, url: URL, keyterms: [String], events: AsyncStream<StreamingEvent>.Continuation) {
        self.apiKey = apiKey
        self.url = url
        self.keyterms = keyterms
        self.events = events
    }

    func run(audio: AsyncStream<[Float]>) async {
        do {
            try await connectWithRetry()
            await reconnectIfLanguageChanged()
        } catch {
            fail(error: error)
        }
        watchdog = Task { await self.watchSilence() }
        for await chunk in audio {
            // Kalıcı hatadan sonra da akış tüketilir ki üretici tarafta ses birikmesin.
            guard !hasFailed else {
                continue
            }
            pending += chunk
            await flush()
        }
        watchdog?.cancel()
        await close()
    }

    /// Dili değiştirir. Bağlıysa hemen yeni dille yeniden bağlanır; bağlantı kuruluyorsa
    /// kurulduktan sonra `reconnectIfLanguageChanged` yeni dile geçer.
    func switchLanguage(to language: MeetingLanguage) async {
        url = deepgramListenURL(language: language, keyterms: keyterms)
        guard isConnected, !isReconnecting, !isClosing else {
            return
        }
        await reconnectIfLanguageChanged()
    }

    func dropConnectionForTesting() {
        socket?.cancel(with: .abnormalClosure, reason: nil)
    }

    // MARK: Bağlantı

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
        // Kapanış süresi bağlanma sürerken dolduysa yeni bağlantı kullanılmaz (açık kalıp ses almasın).
        guard !closeDeadlinePassed else {
            task.cancel(with: .goingAway, reason: nil)
            throw CloudSTTError.connectionFailed(service: "deepgram", reason: "kapanış süresi doldu")
        }
        socket = task
        connectedURL = request.url
        connectionStartSample = acknowledgedSample + unacknowledged.count
        lastMessageAt = .now
        isConnected = true
        receiver = Task { await self.receiveLoop(task: task) }
        deepgramLogger.info("Deepgram bağlandı, başlangıç örneği: \(self.connectionStartSample, privacy: .public)")
    }

    /// `reconnectBudgetSec` boyunca geri çekilmeli (en fazla 5 sn) bağlanmayı dener.
    /// 4xx yanıtı (ör. geçersiz anahtar) yeniden denenmez; kapanış başlarsa denemeler bırakılır.
    private func connectWithRetry() async throws {
        let delays: [Double] = reconnectDelays(budgetSec: reconnectBudgetSec, initialSec: 0.25, capSec: 5)
        var lastError: any Error = CloudSTTError.connectionFailed(service: "deepgram", reason: "deneme yapılmadı")
        for (attempt, delay) in delays.enumerated() {
            // Kapanışta da süre dolana kadar denenir ki kuyruktaki son ses gönderilebilsin.
            guard !closeDeadlinePassed else {
                throw lastError
            }
            do {
                try await connect()
                return
            } catch CloudSTTError.http(let service, let status, let body) where (400..<500).contains(status) {
                throw CloudSTTError.http(service: service, status: status, body: body)
            } catch {
                lastError = error
                deepgramLogger.warning("Deepgram'a bağlanılamadı, deneme \(attempt + 1, privacy: .public): \(String(describing: error), privacy: .private)")
            }
            try await Task.sleep(for: .seconds(delay))
        }
        throw lastError
    }

    /// Bağlantı koptu: kesinleşmemiş sesi yeniden gönderilecekler başına koy, yeniden bağlan.
    private func handleDisconnect(error: any Error) async {
        guard isConnected, !isReconnecting, !isClosing, !hasFailed else {
            return
        }
        deepgramLogger.warning("Deepgram bağlantısı koptu: \(String(describing: error), privacy: .private)")
        await reconnect()
    }

    /// Bağlantı istenen dilde değilse yeni adresle yeniden bağlanır.
    private func reconnectIfLanguageChanged() async {
        guard isConnected, !isReconnecting, !isClosing, !hasFailed, connectedURL != url else {
            return
        }
        deepgramLogger.info("Deepgram dili değişiyor: \(self.url.absoluteString, privacy: .public)")
        await reconnect()
    }

    /// Eski bağlantıyı kapatır, onaylanmamış sesi tekrar sıraya alır ve bağlanır.
    private func reconnect() async {
        isConnected = false
        isReconnecting = true
        let old: URLSessionWebSocketTask? = socket
        socket = nil
        old?.cancel(with: .goingAway, reason: nil)
        // Eski bağlantının kesinleştirmediği ses yeni bağlantıda yeniden yazıya dökülür.
        pending = unacknowledged + inFlight + pending
        unacknowledged = []
        inFlight = []
        do {
            try await connectWithRetry()
            isReconnecting = false
            await reconnectIfLanguageChanged()
            await flush()
        } catch {
            isReconnecting = false
            guard !isClosing else {
                // Kapanış süresi içinde bağlanılamadı: ses dosyada duruyor, son geçiş kapsar; kullanıcıya hata gösterilmez.
                deepgramLogger.warning("Kapanışta yeniden bağlanılamadı, son ses gönderilmedi, örnek: \(self.pending.count, privacy: .public)")
                return
            }
            fail(error: error)
        }
    }

    /// 20 sn hiç mesaj gelmezse bağlantıyı kopmuş say (sessizce takılan bağlantılar için).
    private func watchSilence() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                // Yalnızca iptalde fırlatır: akış bitiyor.
                return
            }
            if isConnected, ContinuousClock.now - lastMessageAt > .seconds(silenceTimeoutSec) {
                await handleDisconnect(error: CloudSTTError.connectionFailed(service: "deepgram", reason: "\(Int(silenceTimeoutSec)) sn yanıt yok"))
            }
        }
    }

    // MARK: Gönderme ve alma

    /// Bekleyen sesi sırayla gönderir; aynı anda tek gönderim yapılır ki ses sırası bozulmasın.
    private func flush() async {
        guard isConnected, !isFlushing else {
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        // Her turda geçerli bağlantı yeniden okunur: gönderim sürerken yeniden bağlanılmış olabilir.
        while isConnected, let sending = socket, !pending.isEmpty {
            inFlight = pending
            pending = []
            do {
                try await sending.send(.data(linear16Data(samples: inFlight)))
                // Gönderim sürerken yeniden bağlanma parçayı zaten yeniden sıraya aldıysa inFlight boştur.
                unacknowledged += inFlight
                inFlight = []
            } catch {
                pending = inFlight + pending
                inFlight = []
                // Eski bağlantının hatası: yeni bağlantı zaten kurulu, onunla devam edilir.
                guard sending === socket else {
                    continue
                }
                isFlushing = false
                await handleDisconnect(error: error)
                return
            }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // Kapanışta ya da yeniden bağlanmada eski bağlantının hatası yok sayılır.
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
            lastMessageAt = .now
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
            guard case .results(let result) = try parseDeepgramMessage(data: data),
                  let event = streamingEvent(result: result, connectionStartSample: connectionStartSample, sampleRate: deepgramSampleRate)
            else {
                return
            }
            if case .final(_, _, let endSec) = event {
                acknowledge(upToSample: Int((endSec * Double(deepgramSampleRate)).rounded()))
            }
            events.yield(event)
        } catch {
            // Tek bozuk mesaj akışı durdurmaz; meeting metni loga yazılmaz, yalnızca boyut.
            deepgramLogger.error("Deepgram mesajı ayrıştırılamadı, \(data.count, privacy: .public) bayt")
        }
    }

    /// Kesin sonucun bittiği yere kadar olan sesi onaylanmış say.
    private func acknowledge(upToSample sample: Int) {
        let count: Int = min(max(0, sample - acknowledgedSample), unacknowledged.count)
        unacknowledged.removeFirst(count)
        acknowledgedSample += count
    }

    // MARK: Kapanış

    /// Ses bitti: kalanı gönder, `CloseStream` ile son sonuçları iste. Tüm kapanış en fazla
    /// `closeDeadlineSec` sürer; süre dolarsa bağlantı kesilir ve bekleyen gönderme/alma biter.
    private func close() async {
        isClosing = true
        let deadline: Task<Void, Never> = Task {
            do {
                try await Task.sleep(for: .seconds(closeDeadlineSec))
                self.expireCloseDeadline()
            } catch {
                // Kapanış süre dolmadan bitti; zamanlayıcı iptal edildi.
            }
        }
        // Süren yeniden bağlanma ya da gönderim bitsin: kuyruktaki son ses sırasıyla gönderilsin.
        while isReconnecting || isFlushing, !closeDeadlinePassed {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                // Bu görev iptal edilmez; iptal gelirse beklemeden kapanılır.
                break
            }
        }
        if let socket, isConnected, !hasFailed, !closeDeadlinePassed {
            while !pending.isEmpty {
                let chunk: [Float] = pending
                pending = []
                do {
                    try await socket.send(.data(linear16Data(samples: chunk)))
                } catch {
                    deepgramLogger.error("Kapanışta ses gönderilemedi: \(String(describing: error), privacy: .private)")
                    break
                }
            }
            do {
                try await socket.send(.string(#"{"type":"CloseStream"}"#))
                await receiver?.value
            } catch {
                deepgramLogger.error("CloseStream gönderilemedi: \(String(describing: error), privacy: .private)")
            }
        }
        deadline.cancel()
        isConnected = false
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session.finishTasksAndInvalidate()
        events.finish()
    }

    /// Kapanış süresi doldu: süren gönderme/alma kesilir, yeniden bağlanma bırakılır.
    private func expireCloseDeadline() {
        closeDeadlinePassed = true
        socket?.cancel(with: .goingAway, reason: nil)
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
        session.finishTasksAndInvalidate()
        deepgramLogger.error("Deepgram akışı durdu: \(String(describing: error), privacy: .private)")
        events.yield(.failed(message: deepgramFailureMessage(error: error)))
        events.finish()
    }
}

/// Kullanıcıya gösterilecek Türkçe hata metni (anahtar içermez).
private func deepgramFailureMessage(error: any Error) -> String {
    switch error {
    case CloudSTTError.connectionFailed:
        return String(localized: "Deepgram'a \(Int(reconnectBudgetSec)) sn boyunca bağlanılamadı; internet bağlantını kontrol et. Ses kaydı sürüyor; metin toplantı sonunda kayıttan yazıya dökülür.")
    default:
        return userFacingMessage(error: error)
    }
}

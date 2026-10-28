import Foundation
import Network
import os

private let loopbackLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "LoopbackRedirect")

/// Yerel uygulama girişinin dönüş adresi (RFC 8252 §7.3): `http://127.0.0.1:<port>/callback`. Tarayıcı girişten sonra
/// buraya döner; `state` bu girişinkiyle aynı olan ilk dönüşü alıp kapanır. Başka yollar ve başka girişe ait dönüşler
/// reddedilir, dinleme sürer: yerel bir süreç ya da web sayfası sahte bir istekle girişi bozamaz. Uzak MCP sunucuları
/// (Notion, Linear, Atlassian) özel adres şemalarını değil, yerel geri dönüşü kabul eder.
public final class LoopbackRedirect: @unchecked Sendable {
    private let listener: NWListener
    private let expectedState: String
    private let queue: DispatchQueue = DispatchQueue(label: "com.senoldogan.AINotepad.loopback")
    private let lock: NSLock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var pending: Result<URL, any Error>?
    private var redirect: String = ""

    /// Dönüş adresi (dinleme başladıktan sonra geçerlidir).
    public var redirectURI: String {
        lock.lock()
        defer { lock.unlock() }
        return redirect
    }

    /// Rastgele boş bir yerel bağlantı noktasında dinlemeye başlar; yalnızca `expectedState` taşıyan dönüşü kabul eder.
    public static func start(expectedState: String) async throws -> LoopbackRedirect {
        let parameters: NWParameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw MCPRemoteError.network(server: "127.0.0.1", reason: "yerel dinleyici açılamadı: \(error.localizedDescription)")
        }
        let redirect: LoopbackRedirect = LoopbackRedirect(listener: listener, expectedState: expectedState)
        try await redirect.listen()
        return redirect
    }

    private init(listener: NWListener, expectedState: String) {
        self.listener = listener
        self.expectedState = expectedState
    }

    /// Dinleyiciyi başlatır; bağlantı işleyicisi başlamadan önce kurulur (hiçbir bağlantı sahipsiz kalmaz). Dinleyici
    /// hazır olmadan beklemeye geçer, durur ya da hata verirse açık hata fırlar.
    private func listen() async throws {
        listener.newConnectionHandler = { [weak self] (connection: NWConnection) -> Void in
            guard let self else {
                connection.cancel()
                return
            }
            self.handle(connection: connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) -> Void in
            let resumed: ResumeOnce = ResumeOnce()
            let listener: NWListener = self.listener
            listener.stateUpdateHandler = { (state: NWListener.State) -> Void in
                let failure: String?
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        failure = "bağlantı noktası alınamadı"
                        break
                    }
                    if resumed.claim() {
                        continuation.resume(returning: port)
                    }
                    return
                case .failed(let error):
                    failure = error.localizedDescription
                case .waiting(let error):
                    failure = "dinleyici beklemede: \(error.localizedDescription)"
                case .cancelled:
                    failure = "dinleyici kapandı"
                default:
                    return
                }
                if let failure, resumed.claim() {
                    continuation.resume(throwing: MCPRemoteError.network(server: "127.0.0.1", reason: failure))
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { redirect = "http://127.0.0.1:\(port)/callback" }
    }

    /// Tarayıcının dönüşünü bekler (en çok `timeoutSec`); dönen tam adres verilir. Bekleyen görev iptal edilirse
    /// (kullanıcı vazgeçti) dinleme kapanır ve `CancellationError` fırlar.
    public func waitForCallback(timeoutSec: Double) async throws -> URL {
        let timeout: Task<Void, Never> = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSec))
            } catch {
                return
            }
            self?.finish(result: .failure(MCPRemoteError.denied(server: "127.0.0.1", reason: "giriş süresi doldu")))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) -> Void in
                lock.lock()
                if let pending {
                    lock.unlock()
                    continuation.resume(with: pending)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            stop()
        }
    }

    /// Dinlemeyi bırakır (giriş bitti ya da vazgeçildi).
    public func stop() {
        listener.cancel()
        finish(result: .failure(CancellationError()))
    }

    private func finish(result: Result<URL, any Error>) {
        lock.lock()
        guard let continuation else {
            if pending == nil {
                pending = result
            }
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        let redirectURI: String = self.redirectURI
        let expectedState: String = self.expectedState
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] (data: Data?, _: NWConnection.ContentContext?, _: Bool, _: NWError?) -> Void in
            let request: String = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let decision: LoopbackDecision = loopbackDecision(request: request, redirectURI: redirectURI, expectedState: expectedState)
            connection.send(content: Data(loopbackResponse(decision: decision).utf8), completion: .contentProcessed { (_: NWError?) -> Void in
                connection.cancel()
            })
            switch decision {
            case .notFound:
                // Tarayıcının favicon gibi başka bir isteği: dönüş beklenmeye devam eder.
                loopbackLogger.debug("Yerel dönüşe başka bir yol geldi")
            case .foreign:
                loopbackLogger.warning("Yerel dönüşe başka bir girişe ait istek geldi, reddedildi")
            case .completed(let url, _):
                self?.listener.cancel()
                self?.finish(result: .success(url))
            }
        }
    }
}

/// Yerel dönüşe gelen isteğin değerlendirmesi.
enum LoopbackDecision: Equatable {
    /// Dönüş yolu değil (ör. favicon): 404, dinleme sürer.
    case notFound
    /// Dönüş yolu ama `state` bu girişin değil: 400, dinleme sürer.
    case foreign
    /// Bu girişin dönüşü; `granted` false ise kullanıcı izin vermedi ya da sunucu hata döndü.
    case completed(url: URL, granted: Bool)
}

/// İsteği değerlendirir: yol tam olarak `/callback` olmalı ve `state` beklenenle aynı olmalı. Saf fonksiyondur.
func loopbackDecision(request: String, redirectURI: String, expectedState: String) -> LoopbackDecision {
    guard let url = callbackURL(request: request, redirectURI: redirectURI) else {
        return .notFound
    }
    let items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard items.first(where: { $0.name == "state" })?.value == expectedState else {
        return .foreign
    }
    return .completed(url: url, granted: !items.contains { $0.name == "error" })
}

/// Tarayıcıya dönen sayfa: başarıda "dönebilirsin", izin verilmediyse ya da istek bu girişe ait değilse açıklama. Saf
/// fonksiyondur.
func loopbackResponse(decision: LoopbackDecision) -> String {
    let (status, title, detail): (String, String, String) = switch decision {
    case .notFound: ("404 Not Found", "Sayfa yok", "Bu adres yalnızca AI-Notepad girişinin dönüşü içindir.")
    case .foreign: ("400 Bad Request", "Bu dönüş bu girişe ait değil", "AI-Notepad'de bağlantıyı yeniden başlat.")
    case .completed(_, true): ("200 OK", "AI-Notepad'e dönebilirsin", "Bağlantı tamamlandı; bu sekmeyi kapatabilirsin.")
    case .completed(_, false): ("200 OK", "Bağlantı tamamlanmadı", "İzin verilmedi; AI-Notepad'e dönüp yeniden deneyebilirsin.")
    }
    let html: String = """
    <!doctype html><html><head><meta charset="utf-8"><title>AI-Notepad</title></head>\
    <body style="font-family:-apple-system,sans-serif;text-align:center;padding-top:80px;background:#FDFCFC;color:#0A0A0A">\
    <h2>\(title)</h2><p>\(detail)</p></body></html>
    """
    return "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
}

/// HTTP isteğinin ilk satırından dönüş adresi: `GET /callback?code=…&state=… HTTP/1.1`; yol tam olarak `/callback`
/// değilse ya da adres kurulamıyorsa nil. Adres istisna atmayan `URLComponents(string:)` ile kurulur (bozuk yüzde
/// kodlaması — `%zz`, tek `%` — ve ASCII dışı bayt yeniden kodlanır): `percentEncodedQuery` ataması bozuk sorguda
/// Objective-C istisnasıyla süreci çökertir, tek bir istek uygulamayı kapatabilirdi. Saf fonksiyondur.
func callbackURL(request: String, redirectURI: String) -> URL? {
    guard let line = request.split(whereSeparator: \.isNewline).first,
          let match = String(line).firstMatch(of: /^GET \/callback(\?[^ ]*)? HTTP\//) else {
        return nil
    }
    return URLComponents(string: redirectURI + (match.1.map { String($0) } ?? ""))?.url
}

/// Devamın yalnızca bir kez sürdürülmesi (dinleyici durumu birden çok kez bildirebilir).
private final class ResumeOnce: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var done: Bool = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else {
            return false
        }
        done = true
        return true
    }
}

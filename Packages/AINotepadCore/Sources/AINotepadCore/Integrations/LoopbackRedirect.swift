import Foundation
import Network
import os

private let loopbackLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "LoopbackRedirect")

/// Yerel uygulama girişinin dönüş adresi (RFC 8252 §7.3): `http://127.0.0.1:<port>/callback`. Tarayıcı girişten sonra
/// buraya döner; tek bir isteği alıp yetki kodunu verir ve kapanır. Uzak MCP sunucuları (Notion, Linear, Atlassian)
/// özel adres şemalarını değil, yerel geri dönüşü kabul eder.
public final class LoopbackRedirect: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue = DispatchQueue(label: "com.senoldogan.AINotepad.loopback")
    private let lock: NSLock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var pending: Result<URL, any Error>?
    public let redirectURI: String

    /// Rastgele boş bir yerel bağlantı noktasında dinlemeye başlar.
    public static func start() async throws -> LoopbackRedirect {
        let parameters: NWParameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw MCPRemoteError.network(server: "127.0.0.1", reason: "yerel dinleyici açılamadı: \(error.localizedDescription)")
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) -> Void in
            let resumed: ResumeOnce = ResumeOnce()
            listener.stateUpdateHandler = { (state: NWListener.State) -> Void in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue, resumed.claim() {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if resumed.claim() {
                        continuation.resume(throwing: MCPRemoteError.network(server: "127.0.0.1", reason: error.localizedDescription))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { (_: NWConnection) -> Void in }
            listener.start(queue: DispatchQueue(label: "com.senoldogan.AINotepad.loopback.start"))
        }
        return LoopbackRedirect(listener: listener, port: port)
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        redirectURI = "http://127.0.0.1:\(port)/callback"
        listener.newConnectionHandler = { [weak self] (connection: NWConnection) -> Void in
            self?.handle(connection: connection)
        }
    }

    /// Tarayıcının dönüşünü bekler (en çok `timeoutSec`); dönen tam adres verilir.
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
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) -> Void in
            lock.lock()
            if let pending {
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] (data: Data?, _: NWConnection.ContentContext?, _: Bool, _: NWError?) -> Void in
            let request: String = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let url: URL? = callbackURL(request: request, redirectURI: self?.redirectURI ?? "")
            let html: String = """
            <!doctype html><html><head><meta charset="utf-8"><title>AI-Notepad</title></head>\
            <body style="font-family:-apple-system,sans-serif;text-align:center;padding-top:80px;background:#FDFCFC;color:#0A0A0A">\
            <h2>AI-Notepad'e dönebilirsin</h2><p>Bağlantı tamamlandı; bu sekmeyi kapatabilirsin.</p></body></html>
            """
            let response: String = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
            connection.send(content: Data(response.utf8), completion: .contentProcessed { (_: NWError?) -> Void in
                connection.cancel()
            })
            guard let url else {
                // Tarayıcının favicon gibi başka bir isteği: dönüş beklenmeye devam eder.
                loopbackLogger.debug("Yerel dönüşe başka bir istek geldi")
                return
            }
            self?.listener.cancel()
            self?.finish(result: .success(url))
        }
    }
}

/// HTTP isteğinin ilk satırından dönüş adresi: `GET /callback?code=…&state=… HTTP/1.1`; başka yol ise nil. Saf
/// fonksiyondur.
func callbackURL(request: String, redirectURI: String) -> URL? {
    guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first,
          let match = String(line).firstMatch(of: /^GET (\/callback[^ ]*) HTTP/),
          let base = URL(string: redirectURI) else {
        return nil
    }
    var components: URLComponents? = URLComponents(url: base, resolvingAgainstBaseURL: false)
    let pathAndQuery: String = String(match.1)
    components?.percentEncodedQuery = pathAndQuery.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
    return components?.url
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

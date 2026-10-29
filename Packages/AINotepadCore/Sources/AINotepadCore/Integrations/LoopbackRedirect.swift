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
    private let appName: String
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
    /// `appName`: tarayıcıya dönen sayfada görünen uygulama adı.
    public static func start(expectedState: String, appName: String) async throws -> LoopbackRedirect {
        let parameters: NWParameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw MCPRemoteError.network(server: "127.0.0.1", reason: "yerel dinleyici açılamadı: \(error.localizedDescription)")
        }
        let redirect: LoopbackRedirect = LoopbackRedirect(listener: listener, expectedState: expectedState, appName: appName)
        try await redirect.listen()
        return redirect
    }

    private init(listener: NWListener, expectedState: String, appName: String) {
        self.listener = listener
        self.expectedState = expectedState
        self.appName = appName
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
        let appName: String = self.appName
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] (data: Data?, _: NWConnection.ContentContext?, _: Bool, _: NWError?) -> Void in
            let request: String = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let decision: LoopbackDecision = loopbackDecision(request: request, redirectURI: redirectURI, expectedState: expectedState)
            connection.send(content: Data(loopbackResponse(decision: decision, appName: appName).utf8), completion: .contentProcessed { (_: NWError?) -> Void in
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

/// Tarayıcıya dönen sayfa: başarıda "dönebilirsin", izin verilmediyse ya da istek bu girişe ait değilse açıklama.
/// Uygulamanın görünümünde (beyaz zemin, durağan pastel gradyan kapak, ses dalgası logosu; koyu temada ters); dış
/// kaynak yüklemez. `appName`: uygulamanın görünen adı (sayfanın başlığı, metinler ve alttaki ad). Saf fonksiyondur.
func loopbackResponse(decision: LoopbackDecision, appName: String) -> String {
    let name: String = htmlEscaped(appName)
    let (status, title, detail, isSuccess): (String, String, String, Bool) = switch decision {
    case .notFound: ("404 Not Found", "Sayfa yok", "Bu adres yalnızca \(name) girişinin dönüşü içindir.", false)
    case .foreign: ("400 Bad Request", "Bu dönüş bu girişe ait değil", "\(name) uygulamasında bağlantıyı yeniden başlat.", false)
    case .completed(_, true): ("200 OK", "Bağlantı tamamlandı", "\(name)'e dönebilirsin; bu sekmeyi kapatabilirsin.", true)
    case .completed(_, false): ("200 OK", "Bağlantı tamamlanmadı", "İzin verilmedi; \(name)'e dönüp yeniden deneyebilirsin.", false)
    }
    let badge: String = isSuccess
        ? "<svg width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M5 12.5l4.5 4.5L19 7\"/></svg>"
        : "<svg width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\"><path d=\"M12 7v6M12 17h.01\"/></svg>"
    let html: String = """
    <!doctype html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\
    <meta name="color-scheme" content="light dark"><title>\(name)</title><style>
    :root{--bg:#FDFCFC;--card:#FFFFFF;--ink:#0A0A0A;--muted:#6B6B6B;--line:#ECEAE8;--ok:#1F9D55;--warn:#D97706}
    @media (prefers-color-scheme:dark){:root{--bg:#0B0B0C;--card:#141416;--ink:#F4F4F5;--muted:#A1A1AA;--line:#26262A}}
    *{box-sizing:border-box;margin:0}
    body{min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);
    font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Inter",system-ui,sans-serif;-webkit-font-smoothing:antialiased;padding:24px}
    .card{width:min(440px,100%);background:var(--card);border:1px solid var(--line);border-radius:24px;overflow:hidden;
    box-shadow:0 24px 60px -24px rgba(0,0,0,.18)}
    .cover{position:relative;height:150px;background:
    radial-gradient(120% 90% at 15% 20%,#F6C9A8 0%,transparent 60%),radial-gradient(110% 90% at 85% 30%,#D9C2F0 0%,transparent 62%),
    radial-gradient(120% 100% at 50% 110%,#F4B6C2 0%,transparent 60%),linear-gradient(135deg,#FBE3D3,#EADCF7);display:grid;place-items:center}
    .cover::after{content:"";position:absolute;inset:0;opacity:.35;mix-blend-mode:multiply;background-image:url("data:image/svg+xml;utf8,\
    <svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2'/>\
    <feColorMatrix values='0 0 0 0 .5 0 0 0 0 .45 0 0 0 0 .45 0 0 0 .55 0'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>")}
    .wave{position:relative;z-index:1;display:flex;gap:5px;align-items:center;height:56px}
    .wave i{display:block;width:5px;border-radius:3px;background:rgba(10,10,10,.72)}
    .body{padding:26px 28px 28px;text-align:center}
    .badge{display:inline-flex;align-items:center;justify-content:center;width:28px;height:28px;border-radius:50%;margin-bottom:14px;color:#fff;
    background:\(isSuccess ? "var(--ok)" : "var(--warn)")}
    h1{font-size:22px;font-weight:600;letter-spacing:-.02em;margin-bottom:8px}
    p{font-size:14px;line-height:1.5;color:var(--muted)}
    .brand{margin-top:22px;font-size:12px;color:var(--muted);letter-spacing:.02em}
    </style></head><body><main class="card"><div class="cover"><div class="wave" aria-hidden="true">\
    <i style="height:14px"></i><i style="height:26px"></i><i style="height:40px"></i><i style="height:22px"></i><i style="height:48px"></i>\
    <i style="height:30px"></i><i style="height:18px"></i><i style="height:36px"></i><i style="height:12px"></i></div></div>\
    <div class="body"><span class="badge" aria-hidden="true">\(badge)</span><h1>\(title)</h1><p>\(detail)</p>\
    <div class="brand">\(name)</div></div></main></body></html>
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

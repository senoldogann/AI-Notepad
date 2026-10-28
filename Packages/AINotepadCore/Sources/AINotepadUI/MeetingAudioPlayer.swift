import AINotepadCore
import AVFoundation
import Foundation
import Observation
import os

private let playerLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AudioPlayer")

/// Toplantı sesinin bir konuşmacı kaydı (`me` / `others`): işlenmişse `.m4a`, işleme sürerken `.caf`; yoksa nil.
public func meetingAudioURL(directory: URL, speaker: Speaker) -> URL? {
    ["m4a", "caf"]
        .map { (ext: String) -> URL in directory.appending(path: "\(speaker.rawValue).\(ext)") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

/// Seçilebilen çalma hızları (sırayla döner).
public let playbackRates: [Float] = [1, 1.25, 1.5, 2, 0.75]

/// Çalma konumunun yayınlanma adımı (saniye): konum bu kadar ilerleyince görünümler güncellenir.
let playbackPublishStep: Double = 0.1

/// Toplantı oynatıcısı: "Sen" ve "Diğerleri" kayıtlarını aynı zaman çizgisinde birlikte çalar (kayıtlar başlangıca
/// hizalı), duraklatır, sarar, hız değiştirir. Konum ~33 ms'de bir okunur, görünür fark olunca (`playbackPublishStep`,
/// ~10/sn) yayınlanır: kelime vurgusu akıcı, çalma ekranı hafif.
@MainActor
@Observable
public final class MeetingAudioPlayer {
    /// Çalan toplantı; çalar boşsa nil.
    public private(set) var meetingID: String?
    public private(set) var isPlaying: Bool = false
    public private(set) var currentTime: Double = 0
    /// Konumun tam saniyesi; yalnızca saniye değişince yayınlanır. Süre etiketleri, konum çubuğu ve şeritteki çizgi
    /// bunu okur: kapakla aynı karttaki çizgi saniyede 10 kez değişince kart (gradyan kapak dahil) baştan çiziliyordu.
    public private(set) var currentSecond: Int = 0
    public private(set) var duration: Double = 0
    public private(set) var rate: Float = 1
    public private(set) var errorMessage: String?

    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var loadedURLs: [URL] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init() {}

    /// Kayıtları (gerekirse) açar ve `startSec`'ten biraz önce birlikte çalmaya başlar (cümlenin başı kaçmasın).
    public func play(meetingID: String, urls: [URL], startSec: Double) {
        if loadedURLs != urls || self.meetingID != meetingID {
            stop()
            do {
                players = try urls.map { (url: URL) -> AVAudioPlayer in
                    let player: AVAudioPlayer = try AVAudioPlayer(contentsOf: url)
                    player.enableRate = true
                    player.prepareToPlay()
                    return player
                }
            } catch {
                playerLogger.error("Ses açılamadı, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                errorMessage = userFacingMessage(error: StorageError.readFailed(path: urls.first?.path ?? meetingID, reason: error.localizedDescription))
                players = []
                return
            }
            loadedURLs = urls
            self.meetingID = meetingID
            duration = players.map(\.duration).max() ?? 0
        }
        errorMessage = nil
        #if os(iOS)
        do {
            // Sessiz modda da çalar; konuşma için ayarlı oturum.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            playerLogger.error("Çalma oturumu açılamadı, hata: \(String(describing: error), privacy: .public)")
            errorMessage = userFacingMessage(error: AudioCaptureError.playbackSessionFailed(code: Int32((error as NSError).code)))
            return
        }
        #endif
        start(at: max(0, startSec - 0.3))
    }

    public func togglePause() {
        if isPlaying {
            players.forEach { $0.pause() }
            isPlaying = false
        } else {
            // Sona gelmişse baştan çalar.
            start(at: currentTime >= duration - 0.2 ? 0 : currentTime)
        }
    }

    /// Konumu yazar; saniye değiştiyse `currentSecond`'ı da.
    private func setPosition(seconds: Double) {
        currentTime = seconds
        let second: Int = Int(seconds)
        if second != currentSecond {
            currentSecond = second
        }
    }

    /// Konuma gider; çalıyorsa oradan sürer.
    public func seek(to seconds: Double) {
        let target: Double = min(max(0, seconds), duration)
        if isPlaying {
            start(at: target)
        } else {
            players.forEach { $0.currentTime = target }
            setPosition(seconds: target)
        }
    }

    /// İleri/geri sarar (ör. ±10 sn).
    public func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Hızı sıradaki değere geçirir.
    public func cycleRate() {
        let index: Int = playbackRates.firstIndex(of: rate) ?? 0
        rate = playbackRates[(index + 1) % playbackRates.count]
        players.forEach { $0.rate = rate }
    }

    /// Çalmayı bitirir ve dosyaları bırakır (toplantı değişince ya da ses silinince).
    public func stop() {
        ticker?.cancel()
        ticker = nil
        players.forEach { $0.stop() }
        players = []
        loadedURLs = []
        meetingID = nil
        isPlaying = false
        setPosition(seconds: 0)
        duration = 0
    }

    /// Tüm kayıtları aynı konumdan, aynı anda başlatır (kayıtlar arası kayma olmasın).
    private func start(at seconds: Double) {
        guard let reference = players.first else {
            return
        }
        let startAt: TimeInterval = reference.deviceCurrentTime + 0.05
        for player in players {
            player.pause()
            player.currentTime = min(seconds, player.duration)
            player.rate = rate
            if seconds < player.duration {
                player.play(atTime: startAt)
            }
        }
        setPosition(seconds: seconds)
        isPlaying = true
        startTicker()
    }

    /// Konumu çalarken ~33 ms'de bir okur, görünür fark olunca yayınlar; tüm kayıtlar bitince durur.
    private func startTicker() {
        ticker?.cancel()
        // Kullanıcı öncelikli: makine yoğunken (derleme, dışa aktarma) konum güncellemesi arka plan işlerinin
        // arkasında kalmasın.
        ticker = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                // Önce beklenir: kayıtlar 50 ms sonra başlar (`play(atTime:)`); hemen bakılırsa "çalmıyor" görünür.
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                let playing: [AVAudioPlayer] = self.players.filter(\.isPlaying)
                if let position = playing.map(\.currentTime).max() {
                    // Konum yalnızca görünür bir fark olunca yayınlanır (~10/sn): kelime vurgusu ve süre için yeter;
                    // her 33 ms'de yayınlamak çalma ekranını boşuna saniyede 30 kez yeniden çizdiriyordu.
                    if abs(position - self.currentTime) >= playbackPublishStep {
                        self.setPosition(seconds: position)
                    }
                } else {
                    self.isPlaying = false
                    return
                }
            }
        }
    }
}

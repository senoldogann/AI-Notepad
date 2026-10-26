import AINotepadCore
import AVFoundation
import Foundation
import Observation
import os

private let playerLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AudioPlayer")

/// Toplantı sesinin bir konuşmacı kaydı (`me` / `others`): işlenmişse `.m4a`, işleme sürerken `.caf`; yoksa nil.
func meetingAudioURL(directory: URL, speaker: Speaker) -> URL? {
    ["m4a", "caf"]
        .map { (ext: String) -> URL in directory.appending(path: "\(speaker.rawValue).\(ext)") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

/// Seçilebilen çalma hızları (sırayla döner).
let playbackRates: [Float] = [1, 1.25, 1.5, 2, 0.75]

/// Toplantı oynatıcısı: "Sen" ve "Diğerleri" kayıtlarını aynı zaman çizgisinde birlikte çalar (kayıtlar başlangıca
/// hizalı), duraklatır, sarar, hız değiştirir. Konum saniyede ~30 kez güncellenir (kelime vurgusu akıcı geçsin).
@MainActor
@Observable
final class MeetingAudioPlayer {
    /// Çalan toplantı; çalar boşsa nil.
    private(set) var meetingID: String?
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    private(set) var errorMessage: String?

    @ObservationIgnored private var players: [AVAudioPlayer] = []
    @ObservationIgnored private var loadedURLs: [URL] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Kayıtları (gerekirse) açar ve `startSec`'ten biraz önce birlikte çalmaya başlar (cümlenin başı kaçmasın).
    func play(meetingID: String, urls: [URL], startSec: Double) {
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
        start(at: max(0, startSec - 0.3))
    }

    func togglePause() {
        if isPlaying {
            players.forEach { $0.pause() }
            isPlaying = false
        } else {
            // Sona gelmişse baştan çalar.
            start(at: currentTime >= duration - 0.2 ? 0 : currentTime)
        }
    }

    /// Konuma gider; çalıyorsa oradan sürer.
    func seek(to seconds: Double) {
        let target: Double = min(max(0, seconds), duration)
        if isPlaying {
            start(at: target)
        } else {
            players.forEach { $0.currentTime = target }
            currentTime = target
        }
    }

    /// İleri/geri sarar (ör. ±10 sn).
    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Hızı sıradaki değere geçirir.
    func cycleRate() {
        let index: Int = playbackRates.firstIndex(of: rate) ?? 0
        rate = playbackRates[(index + 1) % playbackRates.count]
        players.forEach { $0.rate = rate }
    }

    /// Çalmayı bitirir ve dosyaları bırakır (toplantı değişince ya da ses silinince).
    func stop() {
        ticker?.cancel()
        ticker = nil
        players.forEach { $0.stop() }
        players = []
        loadedURLs = []
        meetingID = nil
        isPlaying = false
        currentTime = 0
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
        currentTime = seconds
        isPlaying = true
        startTicker()
    }

    /// Konumu çalarken saniyede ~30 kez günceller; tüm kayıtlar bitince durur.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
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
                    self.currentTime = position
                } else {
                    self.isPlaying = false
                    return
                }
            }
        }
    }
}

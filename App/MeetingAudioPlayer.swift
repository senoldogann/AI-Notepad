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

/// Toplantılar penceresindeki ses çalar: satırın anından çalar, duraklatır, konum değiştirir.
@MainActor
@Observable
final class MeetingAudioPlayer {
    /// Çalan toplantı ve konuşmacı kaydı; çalar boşsa nil.
    private(set) var meetingID: String?
    private(set) var speaker: Speaker?
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Dosyayı (gerekirse) açar ve `startSec`'ten biraz önce çalmaya başlar (cümlenin başı kaçmasın).
    func play(url: URL, meetingID: String, speaker: Speaker, startSec: Double) {
        do {
            if player?.url != url {
                stop()
                let opened: AVAudioPlayer = try AVAudioPlayer(contentsOf: url)
                opened.prepareToPlay()
                player = opened
                duration = opened.duration
            }
            guard let player else {
                return
            }
            self.meetingID = meetingID
            self.speaker = speaker
            errorMessage = nil
            player.currentTime = min(max(0, startSec - 0.3), duration)
            player.play()
            isPlaying = true
            startTicker()
        } catch {
            playerLogger.error("Ses açılamadı, dosya: \(url.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            errorMessage = userFacingMessage(error: StorageError.readFailed(path: url.path, reason: error.localizedDescription))
        }
    }

    func togglePause() {
        guard let player else {
            return
        }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to seconds: Double) {
        guard let player else {
            return
        }
        player.currentTime = min(max(0, seconds), duration)
        currentTime = player.currentTime
    }

    /// Çalmayı bitirir ve dosyayı bırakır (toplantı değişince ya da ses silinince).
    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        meetingID = nil
        speaker = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// Konumu çalarken dört kez/sn günceller; çalma bitince durur.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else {
                    return
                }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }
}

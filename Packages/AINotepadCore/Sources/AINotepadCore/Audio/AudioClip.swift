import AVFoundation
import Foundation

/// Ses klibi çıkarılamadı.
public enum AudioClipError: Error, Equatable {
    case noAudio(path: String)
    case exportFailed(path: String, reason: String)
}

/// Klip aralığı: paragrafın başından biraz önce (cümlenin başı kesilmesin) sonundan biraz sonrasına; 0'ın altına inmez.
/// Saf fonksiyondur.
public func clipRange(startSec: Double, endSec: Double) -> (start: Double, end: Double) {
    (start: max(0, startSec - 0.5), end: max(startSec, endSec) + 0.5)
}

/// Toplantının seslerinden ("Sen" ve "Diğerleri" aynı zaman çizgisinde) bir aralığı tek M4A klip olarak `destination`'a
/// yazar; iki kayıt üst üste karışır. Aralık kaydın sonunu aşarsa kaydın sonunda biter.
public func exportAudioClip(sources: [URL], startSec: Double, endSec: Double, destination: URL) async throws {
    let composition: AVMutableComposition = AVMutableComposition()
    let start: CMTime = CMTime(seconds: startSec, preferredTimescale: 600)
    var inserted: Int = 0
    for source in sources {
        let asset: AVURLAsset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw AudioClipError.exportFailed(path: source.path, reason: error.localizedDescription)
        }
        // Boş kayıt (ör. yüz yüze modda "Sen") ya da aralıktan önce biten kayıt atlanır.
        guard let track = tracks.first, duration > start else {
            continue
        }
        let end: CMTime = CMTimeMinimum(CMTime(seconds: endSec, preferredTimescale: 600), duration)
        guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioClipError.exportFailed(path: source.path, reason: "ses izi eklenemedi")
        }
        do {
            try target.insertTimeRange(CMTimeRange(start: start, end: end), of: track, at: .zero)
        } catch {
            throw AudioClipError.exportFailed(path: source.path, reason: error.localizedDescription)
        }
        inserted += 1
    }
    guard inserted > 0 else {
        throw AudioClipError.noAudio(path: sources.first?.deletingLastPathComponent().path ?? "")
    }
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
        throw AudioClipError.exportFailed(path: destination.path, reason: "dışa aktarma oturumu kurulamadı")
    }
    do {
        try await session.export(to: destination, as: .m4a)
    } catch {
        throw AudioClipError.exportFailed(path: destination.path, reason: error.localizedDescription)
    }
}

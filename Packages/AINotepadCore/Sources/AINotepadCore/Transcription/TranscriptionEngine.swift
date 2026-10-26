import Foundation

/// Sesi yazıya döken motor. Örnekler 16 kHz mono Float32'dir.
public protocol TranscriptionEngine: Sendable {
    /// Dil kodu → log olasılık (ör. "fi": -0.2). WhisperKit yalnızca en olası dili döndürür.
    func detectLanguage(samples: [Float]) async throws -> [String: Float]
    /// Konuşma yoksa boş metin döner.
    func transcribe(samples: [Float], language: MeetingLanguage) async throws -> String
}

/// Yazıya dökme katmanının hataları.
public enum TranscriptionError: Error, Equatable {
    case modelLoadFailed(model: String, reason: String)
    case transcriptionFailed(sampleCount: Int, language: String, reason: String)
    /// Yerel konuşmacı ayırma (SpeakerKit) başarısız oldu.
    case diarizationFailed(reason: String)
}

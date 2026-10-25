import Foundation

/// Yazıya dökme katmanının hataları.
public enum TranscriptionError: Error, Equatable {
    /// Dil algılama sonucunda Fince ya da İngilizce olasılığı yok.
    case languageProbabilitiesMissing(availableCodes: [String])
    case modelLoadFailed(model: String, reason: String)
    case transcriptionFailed(sampleCount: Int, language: String, reason: String)
}

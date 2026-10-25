import Foundation

/// Whisper'ın sessizlik ve gürültüde uydurduğu, bir bölümün tamamını oluşturan ifadeler
/// (küçük harf, noktalamasız). WhisperKit `noSpeechProb` hesaplamadığı için bu liste gerekir.
let knownHallucinations: Set<String> = [
    "kiitos",
    "kiitos katsomisesta",
    "kiitos kun katsoit",
    "thank you",
    "thanks for watching",
    "thank you for watching",
]

/// Metnin tamamı bilinen bir uydurma ifadeyse boş metin, değilse metnin kendisini döndürür.
public func dropHallucination(text: String) -> String {
    knownHallucinations.contains(normalizedPhrase(text: text)) ? "" : text
}

/// Karşılaştırma için küçük harfe çevirir, noktalamayı atar, boşlukları tekleştirir.
private func normalizedPhrase(text: String) -> String {
    let lettersAndSpaces: String = String(text.lowercased().unicodeScalars.filter { (scalar: Unicode.Scalar) -> Bool in
        CharacterSet.letters.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
    }.map(Character.init))
    return lettersAndSpaces.split(separator: " ").joined(separator: " ")
}

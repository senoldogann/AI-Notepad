import Foundation

/// Mesaj listede yoksa sona ekler (aynı hata tekrar tekrar gösterilmesin). Saf fonksiyondur.
public func appendUnique(messages: [String], message: String) -> [String] {
    messages.contains(message) ? messages : messages + [message]
}

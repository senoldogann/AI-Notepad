import Foundation

/// Bulut konuşma tanıma servislerinin hataları. Anahtar değeri hiçbir zaman hataya girmez.
public enum CloudSTTError: Error, Equatable {
    case http(service: String, status: Int, body: String)
    case malformedMessage(service: String, body: String)
    case connectionFailed(service: String, reason: String)
}

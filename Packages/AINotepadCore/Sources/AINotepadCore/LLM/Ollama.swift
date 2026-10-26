import Foundation

/// Ollama'ya ulaşılamadı ya da yanıt beklenmedik.
public enum OllamaError: Error, Equatable {
    case unreachable(url: String, reason: String)
    case http(url: String, status: Int, body: String)
    case malformed(body: String)
}

/// Ollama'nın yüklü modelleri (`GET /api/tags`); `baseURL` OpenAI uyumlu adres (`…/v1`) ya da kök olabilir.
public func ollamaModels(baseURL: URL) async throws -> [String] {
    let root: URL = baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL
    let url: URL = root.appending(path: "api/tags")
    var request: URLRequest = URLRequest(url: url)
    request.timeoutInterval = 5
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        throw OllamaError.unreachable(url: url.absoluteString, reason: error.localizedDescription)
    }
    let body: String = String(decoding: data, as: UTF8.self)
    guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
        throw OllamaError.http(url: url.absoluteString, status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
    }
    struct Tags: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }
    do {
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
    } catch {
        throw OllamaError.malformed(body: body)
    }
}

/// Model sohbet için kullanılabilir mi (gömme modelleri değil). Saf fonksiyondur.
public func isChatModel(name: String) -> Bool {
    let lower: String = name.lowercased()
    return !["embed", "bge-", "e5-", "minilm", "nomic"].contains { lower.contains($0) }
}

/// Model Ollama'nın bulutunda mı çalışıyor (internet gerekir, toplantı metni Ollama'ya gider). Saf fonksiyondur.
public func isOllamaCloudModel(name: String) -> Bool {
    name.lowercased().contains("cloud")
}

/// Not için önerilen model: önce Mac'te çalışanlardan bilinen iyi aileler (gpt-oss, qwen3, gemma, llama, mistral),
/// yoksa herhangi bir yerel sohbet modeli, yoksa bulut modeli. Saf fonksiyondur.
public func recommendedOllamaModel(names: [String]) -> String? {
    let chat: [String] = names.filter(isChatModel)
    let preferred: [String] = ["gpt-oss", "qwen3", "gemma4", "gemma3", "llama3", "mistral"]
    let rank: (String) -> Int = { (name: String) -> Int in
        preferred.firstIndex { name.lowercased().hasPrefix($0) } ?? preferred.count
    }
    let local: [String] = chat.filter { !isOllamaCloudModel(name: $0) }.sorted { rank($0) < rank($1) }
    let cloud: [String] = chat.filter(isOllamaCloudModel).sorted { rank($0) < rank($1) }
    return local.first ?? cloud.first
}

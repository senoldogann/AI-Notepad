import Foundation

/// AI-Notepad'in MCP sunucusunu tek tıkla eklenebilen masaüstü yapay zekâ uygulamaları. Her biri yapılandırmasını
/// kullanıcının ev klasöründe bir JSON dosyasında tutar.
public enum MCPClient: String, CaseIterable, Sendable {
    case claudeDesktop
    case cursor
    case vsCode

    /// Uygulamanın adı.
    public var displayName: String {
        switch self {
        case .claudeDesktop: "Claude"
        case .cursor: "Cursor"
        case .vsCode: "Visual Studio Code"
        }
    }

    /// Uygulamanın kurulu olduğu yer (simge ve "yüklü mü" için).
    public var applicationPath: String {
        switch self {
        case .claudeDesktop: "/Applications/Claude.app"
        case .cursor: "/Applications/Cursor.app"
        case .vsCode: "/Applications/Visual Studio Code.app"
        }
    }

    /// Yapılandırma dosyasının ev klasörüne göre yolu.
    var configRelativePath: String {
        switch self {
        case .claudeDesktop: "Library/Application Support/Claude/claude_desktop_config.json"
        case .cursor: ".cursor/mcp.json"
        case .vsCode: "Library/Application Support/Code/User/mcp.json"
        }
    }

    /// Sunucuların tutulduğu anahtar (VS Code'da `servers`, diğerlerinde `mcpServers`).
    var serversKey: String {
        switch self {
        case .claudeDesktop, .cursor: "mcpServers"
        case .vsCode: "servers"
        }
    }

    /// Yapılandırma dosyası.
    public func configFile(home: URL) -> URL {
        home.appending(path: configRelativePath)
    }
}

/// Yapılandırmadaki sunucu adı.
public let mcpServerName: String = "ai-notepad"

/// MCP istemci yapılandırması hataları. Bozuk dosyanın üzerine yazılmaz: kullanıcı ayarları kaybolmasın.
public enum MCPConfigError: Error, Equatable {
    /// Dosya JSON nesnesi değil ya da okunamadı.
    case invalidConfig(path: String, reason: String)
    case writeFailed(path: String, reason: String)
}

/// AI-Notepad sunucusunun yapılandırma girdisi: uygulamanın kendisi `--mcp` ile (VS Code `type` ister).
func mcpServerEntry(client: MCPClient, executablePath: String) -> JSONValue {
    var entry: [String: JSONValue] = ["command": .string(executablePath), "args": .array([.string("--mcp")])]
    if client == .vsCode {
        entry["type"] = .string("stdio")
    }
    return .object(entry)
}

/// Yapılandırmaya AI-Notepad sunucusunu ekler (varsa günceller); diğer sunucular ve ayarlar aynen kalır. Kök nesne
/// değilse ya da sunucu alanı nesne değilse `invalidConfig`. Saf fonksiyondur.
public func mcpConfigAdding(config: JSONValue, client: MCPClient, executablePath: String, path: String) throws -> JSONValue {
    guard case .object(var root) = config else {
        throw MCPConfigError.invalidConfig(path: path, reason: "kök JSON nesnesi değil")
    }
    var servers: [String: JSONValue] = [:]
    switch root[client.serversKey] {
    case .none:
        break
    case .some(.object(let existing)):
        servers = existing
    case .some:
        throw MCPConfigError.invalidConfig(path: path, reason: "\(client.serversKey) nesne değil")
    }
    servers[mcpServerName] = mcpServerEntry(client: client, executablePath: executablePath)
    root[client.serversKey] = .object(servers)
    return .object(root)
}

/// Yapılandırmadan AI-Notepad sunucusunu çıkarır; başka hiçbir şeye dokunmaz. Saf fonksiyondur.
public func mcpConfigRemoving(config: JSONValue, client: MCPClient) -> JSONValue {
    guard case .object(var root) = config, case .object(var servers) = root[client.serversKey] else {
        return config
    }
    servers[mcpServerName] = nil
    root[client.serversKey] = .object(servers)
    return .object(root)
}

/// Yapılandırmada bu uygulamayı gösteren AI-Notepad sunucusu var mı. Saf fonksiyondur.
public func isMCPServerConnected(config: JSONValue, client: MCPClient, executablePath: String) -> Bool {
    guard case .object(let root) = config, case .object(let servers) = root[client.serversKey],
          case .object(let entry) = servers[mcpServerName] else {
        return false
    }
    return entry["command"] == .string(executablePath)
}

/// Yapılandırma dosyasını okur; dosya yoksa boş nesne (uygulama henüz yapılandırılmamış). Okunamazsa ya da JSON
/// değilse `invalidConfig`.
public func readMCPConfig(file: URL) throws -> JSONValue {
    guard FileManager.default.fileExists(atPath: file.path) else {
        return .object([:])
    }
    do {
        let data: Data = try Data(contentsOf: file)
        // Boş dosya (bazı uygulamalar böyle bırakır) boş yapılandırmadır.
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            return .object([:])
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
        throw MCPConfigError.invalidConfig(path: file.path, reason: error.localizedDescription)
    }
}

/// Yapılandırmayı okunur biçimde, atomik yazar (klasör yoksa oluşturur).
public func writeMCPConfig(config: JSONValue, file: URL) throws {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: file, options: .atomic)
    } catch {
        throw MCPConfigError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Uygulamaya AI-Notepad sunucusunu ekler (okur, birleştirir, yazar). Bozuk dosyanın üzerine yazmaz.
public func connectMCPClient(client: MCPClient, executablePath: String, home: URL) throws {
    let file: URL = client.configFile(home: home)
    let updated: JSONValue = try mcpConfigAdding(config: try readMCPConfig(file: file), client: client, executablePath: executablePath, path: file.path)
    try writeMCPConfig(config: updated, file: file)
}

/// Uygulamadan AI-Notepad sunucusunu kaldırır.
public func disconnectMCPClient(client: MCPClient, home: URL) throws {
    let file: URL = client.configFile(home: home)
    try writeMCPConfig(config: mcpConfigRemoving(config: try readMCPConfig(file: file), client: client), file: file)
}

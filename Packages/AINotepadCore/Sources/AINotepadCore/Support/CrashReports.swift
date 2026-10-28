import Foundation

/// Sonlandırma nedeni bu uzunlukta kesilir (dosya yolu gibi uzun ayrıntılar arayüzü şişirmesin).
private let terminationReasonLimit: Int = 200

/// Teşhisin türü.
public enum CrashDiagnosticKind: String, Sendable, Equatable {
    case crash
    case hang
}

/// MetricKit teşhisinin (`MXCrashDiagnostic`, `MXHangDiagnostic`) özeti: sürüm, sistem, istisna ve sorunlu iş
/// parçacığının en üstteki çerçeveleri. Toplantı içeriği ya da anahtar içermez (MetricKit bunları toplamaz).
public struct CrashDiagnostic: Sendable, Equatable {
    public let kind: CrashDiagnosticKind
    public let appVersion: String
    public let appBuild: String
    public let osVersion: String
    public let architecture: String?
    public let exceptionType: Int?
    public let exceptionCode: Int?
    public let signal: Int?
    public let terminationReason: String?
    /// Donma süresi (MetricKit metni, ör. "6 sec").
    public let hangDuration: String?
    /// Sorunlu iş parçacığının çerçeveleri, en üstten (çöktüğü yer) aşağı: `İkili + 0xKaydırma` (simgesiz).
    public let topFrames: [String]
}

/// Diskteki bir teşhis paketi (`CrashReports/<kimlik>.json`): içindeki çökme ve donmalar.
public struct CrashReport: Sendable, Equatable, Identifiable {
    /// Dosya adı (uzantısız).
    public let id: String
    public let receivedAt: Date
    /// Önce çökmeler, sonra donmalar; en az bir öğe.
    public let diagnostics: [CrashDiagnostic]

    public init(id: String, receivedAt: Date, diagnostics: [CrashDiagnostic]) {
        self.id = id
        self.receivedAt = receivedAt
        self.diagnostics = diagnostics
    }

    /// Pakette çökme var (yalnız donma değil).
    public var containsCrash: Bool {
        diagnostics.contains { $0.kind == .crash }
    }

    /// Raporun öne çıkan teşhisi: varsa ilk çökme, yoksa ilk donma.
    public var primaryDiagnostic: CrashDiagnostic {
        diagnostics.first { $0.kind == .crash } ?? diagnostics[0]
    }
}

/// Raporları okumanın sonucu: okunanlar (yeniden eskiye) ve okunamayan dosyaların adları (biri diğerlerini engellemez).
public struct CrashReportLoadResult: Sendable, Equatable {
    public let reports: [CrashReport]
    public let unreadableFiles: [String]
}

// MARK: MetricKit JSON (MXDiagnosticPayload.jsonRepresentation())

private struct DiagnosticPayloadJSON: Decodable {
    let crashDiagnostics: [DiagnosticJSON]?
    let hangDiagnostics: [DiagnosticJSON]?
}

private struct DiagnosticJSON: Decodable {
    let callStackTree: CallStackTreeJSON?
    let diagnosticMetaData: DiagnosticMetaDataJSON
}

private struct CallStackTreeJSON: Decodable {
    let callStacks: [CallStackJSON]
}

private struct CallStackJSON: Decodable {
    let threadAttributed: Bool?
    let callStackRootFrames: [CallStackFrameJSON]
}

private struct CallStackFrameJSON: Decodable {
    let binaryName: String?
    let offsetIntoBinaryTextSegment: UInt64?
    let address: UInt64?
    let subFrames: [CallStackFrameJSON]?
}

private struct DiagnosticMetaDataJSON: Decodable {
    let appVersion: String?
    let appBuildVersion: String?
    let osVersion: String?
    let platformArchitecture: String?
    let exceptionType: Int?
    let exceptionCode: Int?
    let signal: Int?
    let terminationReason: String?
    let hangDuration: LooseText?
}

/// Metin ya da sayı olarak gelebilen alan (MetricKit sürümleri `hangDuration`'ı farklı yazabilir).
private struct LooseText: Decodable {
    let text: String

    init(from decoder: any Decoder) throws {
        let container: any SingleValueDecodingContainer = try decoder.singleValueContainer()
        do {
            text = try container.decode(String.self)
        } catch DecodingError.typeMismatch {
            // Metin değilse sayı olmalı; o da değilse çözme hatası yukarı iletilir.
            text = String(try container.decode(Double.self))
        }
    }
}

/// Teşhis paketinin (MetricKit JSON) çökme ve donmalarını özetler: önce çökmeler, sonra donmalar. Pakette ikisi de
/// yoksa boş (CPU ve disk teşhisleri saklanmaz). Çözülemeyen JSON `DecodingError` fırlatır. Saf fonksiyondur.
public func crashDiagnostics(payload: Data) throws -> [CrashDiagnostic] {
    let decoded: DiagnosticPayloadJSON = try JSONDecoder().decode(DiagnosticPayloadJSON.self, from: payload)
    let crashes: [CrashDiagnostic] = (decoded.crashDiagnostics ?? []).map { (item: DiagnosticJSON) -> CrashDiagnostic in
        crashDiagnostic(json: item, kind: .crash)
    }
    let hangs: [CrashDiagnostic] = (decoded.hangDiagnostics ?? []).map { (item: DiagnosticJSON) -> CrashDiagnostic in
        crashDiagnostic(json: item, kind: .hang)
    }
    return crashes + hangs
}

private func crashDiagnostic(json: DiagnosticJSON, kind: CrashDiagnosticKind) -> CrashDiagnostic {
    let meta: DiagnosticMetaDataJSON = json.diagnosticMetaData
    return CrashDiagnostic(
        kind: kind,
        appVersion: meta.appVersion ?? "?",
        appBuild: meta.appBuildVersion ?? "?",
        osVersion: meta.osVersion ?? "?",
        architecture: meta.platformArchitecture,
        exceptionType: meta.exceptionType,
        exceptionCode: meta.exceptionCode,
        signal: meta.signal,
        terminationReason: meta.terminationReason.map { String($0.prefix(terminationReasonLimit)) },
        hangDuration: meta.hangDuration?.text,
        topFrames: json.callStackTree.map { topFrames(tree: $0) } ?? []
    )
}

/// Sorunlu iş parçacığının (`threadAttributed`; yoksa ilk) çerçeveleri en üstten aşağı: kök çerçeve yığının tepesidir,
/// `subFrames` onu çağıranlara iner.
private func topFrames(tree: CallStackTreeJSON) -> [String] {
    guard let stack = tree.callStacks.first(where: { $0.threadAttributed == true }) ?? tree.callStacks.first,
          let root = stack.callStackRootFrames.first else {
        return []
    }
    var frames: [String] = []
    var current: CallStackFrameJSON? = root
    while let frame = current {
        frames.append(frameText(frame: frame))
        current = frame.subFrames?.first
    }
    return frames
}

private func frameText(frame: CallStackFrameJSON) -> String {
    let binary: String = frame.binaryName ?? "?"
    if let offset = frame.offsetIntoBinaryTextSegment {
        return "\(binary) + 0x\(String(offset, radix: 16))"
    }
    return "\(binary) 0x\(String(frame.address ?? 0, radix: 16))"
}

/// Mach istisna türünün adı (ör. 1 → EXC_BAD_ACCESS); bilinmiyorsa sayı. Saf fonksiyondur.
public func machExceptionName(type: Int) -> String {
    switch type {
    case 1: "EXC_BAD_ACCESS"
    case 2: "EXC_BAD_INSTRUCTION"
    case 3: "EXC_ARITHMETIC"
    case 4: "EXC_EMULATION"
    case 5: "EXC_SOFTWARE"
    case 6: "EXC_BREAKPOINT"
    case 10: "EXC_CRASH"
    case 11: "EXC_RESOURCE"
    case 12: "EXC_GUARD"
    default: "EXC_\(type)"
    }
}

/// Unix sinyalinin adı (ör. 11 → SIGSEGV); bilinmiyorsa sayı. Saf fonksiyondur.
public func signalName(signal: Int) -> String {
    switch signal {
    case 4: "SIGILL"
    case 5: "SIGTRAP"
    case 6: "SIGABRT"
    case 8: "SIGFPE"
    case 9: "SIGKILL"
    case 10: "SIGBUS"
    case 11: "SIGSEGV"
    case 13: "SIGPIPE"
    default: "SIG\(signal)"
    }
}

/// Teşhisin kısa teknik nedeni: çökmede istisna ve sinyal (ör. "EXC_BAD_ACCESS · SIGSEGV"), donmada süre. Bilgi
/// yoksa boş. Saf fonksiyondur.
public func crashCause(diagnostic: CrashDiagnostic) -> String {
    switch diagnostic.kind {
    case .crash:
        let parts: [String] = [diagnostic.exceptionType.map { machExceptionName(type: $0) }, diagnostic.signal.map { signalName(signal: $0) }]
            .compactMap { $0 }
        return parts.joined(separator: " · ")
    case .hang:
        return diagnostic.hangDuration ?? ""
    }
}

/// Raporların hangisinin bildirim şeridinde gösterileceği: görülmemiş, çökme içeren en yeni rapor (yalnız donma
/// içerenler şeritte değil, Ayarlar'da listelenir). `reports` yeniden eskiye sıralıdır. Saf fonksiyondur.
public func crashReportToAnnounce(reports: [CrashReport], seenIDs: Set<String>) -> CrashReport? {
    reports.first { $0.containsCrash && !seenIDs.contains($0.id) }
}

/// Raporun arayüz başlığı: tür ve kısa neden (ör. "Çökme · EXC_BAD_ACCESS · SIGSEGV"). Saf fonksiyondur.
public func crashReportHeadline(diagnostic: CrashDiagnostic) -> String {
    let kind: String = diagnostic.kind == .crash ? String(localized: "Çökme") : String(localized: "Donma")
    let cause: String = crashCause(diagnostic: diagnostic)
    return cause.isEmpty ? kind : "\(kind) · \(cause)"
}

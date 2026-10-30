import AINotepadCore
import Foundation

// Paylaşılan koddaki telemetri noktaları: abonelik sürümünde `HostedTelemetryCenter`'a gider (paylaşım açıksa),
// geliştirici sürümünde derlenmez bile; hiçbir şey kaydedilmez ve gönderilmez (bkz. `telemetrySendingAllowed`).

/// Güvenilirlik olayını sayar.
@MainActor
func recordTelemetryCount(kind: TelemetryCountKind) {
    #if HOSTED_EDITION
    HostedTelemetryCenter.shared.record(count: kind)
    #endif
}

/// Özellik kullanımını işler.
@MainActor
func recordFeatureUsage(feature: TelemetryFeature) {
    #if HOSTED_EDITION
    HostedTelemetryCenter.shared.record(feature: feature)
    #endif
}

/// Not yazımının sonucunu işler: `writingStartedAt` notun yazılmaya başladığı an (yazılmadıysa nil; işleme daha önce
/// durdu). Not yazıldıysa süresi, yazılamadıysa başarısızlığı sayılır; not yazılmayan (metinsiz) toplantı sayılmaz.
@MainActor
func recordNoteOutcome(result: MeetingRecord, writingStartedAt: ContinuousClock.Instant?) {
    #if HOSTED_EDITION
    guard let writingStartedAt else {
        return
    }
    switch noteGenerationOutcome(record: result) {
    case .written:
        HostedTelemetryCenter.shared.record(duration: .noteGenerationDuration, seconds: Double((ContinuousClock.now - writingStartedAt).components.seconds))
    case .failed:
        HostedTelemetryCenter.shared.record(count: .noteGenerationFailed)
    case .notWritten:
        break
    }
    #endif
}

import AINotepadCore
import AINotepadUI
import AppKit
import os
import SwiftUI

private let gateLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedGate")

/// Bu Mac'te kayıtlı oturumun kullanıcısı (Anahtar Zinciri; ağa gidilmez); oturum yoksa nil. Servis adı tanımlı
/// değilse ya da Anahtar Zinciri okunamazsa hata fırlar.
func hostedStoredUserID(bundle: Bundle) throws -> String? {
    try HostedKeychainTokenStorage(service: hostedKeychainService(bundle: bundle)).load()?.userId
}

/// Sitedeki yasal sayfa (gizlilik, koşullar); site adresi geçersizse nil (bağlantı gösterilmez, hata loglanır).
private func hostedLegalURL(path: String) -> URL? {
    do {
        return try HostedServices.siteBase().appending(path: path)
    } catch {
        gateLogger.error("Site adresi geçersiz, yasal bağlantı gösterilmiyor, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

/// Giriş kapısı (abonelik sürümü): oturum yokken ana pencere yalnızca bunu gösterir — solda dalgalanan ses çizgili film
/// kartı, sağda logo, tek cümlelik tanıtım, "Apple ile devam et" ve "Google ile devam et" (uygulama içi giriş
/// penceresinde doğrudan o sağlayıcı), deneme satırı ve gizlilik/koşullar bağlantıları. Kenar çubuğu, toplantılar,
/// ayarlar ve kayıt yoktur. Giriş tamamlanınca kurulum (izinler…) ya da ana sayfa açılır.
struct HostedSignInGate: View {
    let account: HostedAccount

    var body: some View {
        HStack(spacing: 0) {
            // Gradyan durağandır (bulanık katman hiç yeniden çizilmez); yalnızca üstündeki ince çizgiler kayar.
            FilmGradient(seed: "gistsmith-giris", palette: .violet)
                .overlay { ListeningWaves() }
                .overlay(alignment: .bottomLeading) {
                    Text("Toplantılarını dinler, notunu yazar")
                        .appFont(size: 30, weight: .regular)
                        .tracking(-0.5)
                        .foregroundStyle(Color.black.opacity(0.78))
                        .padding(36)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(16)
                .frame(minWidth: 300, maxWidth: 520)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { FlowingLines(seed: "gistsmith-giris", lineCount: 12, isAnimated: false) }
        .pageBackground()
        .task { await account.refresh() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(verbatim: appName)
                .appFont(size: 34, weight: .regular)
                .tracking(-0.6)
                .foregroundStyle(Theme.ink)
            Text("Teams, Zoom ve yüz yüze toplantılarını canlı yazıya döker; bitince notun hazır, görevlerin en üstte.")
                .appFont(size: 15, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            switch account.state {
            case .unavailable(let message):
                NoticeText(message as String, severity: .error)
                    .appFont(size: 13, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
            case .loading, .signedOut, .signedIn, .signedInStatusUnknown:
                VStack(alignment: .leading, spacing: 12) {
                    HostedProviderButtons(account: account, width: 252)
                    HostedSignInHint(account: account)
                    Label("3 toplantı ya da 7 gün ücretsiz", systemImage: "sparkles")
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 4)
                }
                .padding(.top, 6)
                HostedAccountError(account: account)
            }
            HostedAccountDataNotice(account: account)
            HStack(spacing: 14) {
                if let privacy = hostedLegalURL(path: "privacy") {
                    Link("Gizlilik", destination: privacy)
                }
                if let terms = hostedLegalURL(path: "terms") {
                    Link("Koşullar", destination: terms)
                }
                Spacer(minLength: 0)
                Button("Çık") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.hoverPlain)
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .padding(.top, 12)
        }
        // En küçük genişlik: macOS 15 pencerenin en küçük boyutunu sıfır genişlik önererek hesaplar; dikeyde sabit
        // metinler o genişlikte harf harf kırılıp pencereyi binlerce punto uzatıyordu (içerik ekranın altında kalırdı).
        .frame(minWidth: 340, maxWidth: 420, alignment: .leading)
        .padding(40)
    }
}

/// Giriş yapılmış ama hesabın verisi açılmamışsa kapıdaki neden: önceki toplantılar hesaba taşınamadı ("Yeniden dene";
/// hiçbir şey silinmedi) ya da başka hesapla giriş yapıldı ve uygulama yeniden başlayacak. Giriş yoksa görünmez.
private struct HostedAccountDataNotice: View {
    let account: HostedAccount

    var body: some View {
        if account.hasSession == true {
            switch account.dataState {
            case .notLoaded, .loaded:
                EmptyView()
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    NoticeText(message as String, severity: .error)
                        .appFont(size: 13, weight: .regular)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Yeniden dene") { account.retryAccountData() }
                        .buttonStyle(.hoverPlain)
                        .appFont(size: 13, weight: .medium)
                }
            case .relaunchRequired:
                NoticeText("Başka bir hesapla giriş yaptın. Önceki hesabın kaydı ya da işlenen toplantısı bitince uygulama yeniden başlar ve bu hesabın toplantılarını açar.", severity: .info)
                    .appFont(size: 13, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Dinleyen ses dalgası: kartın ortasında yatayda uzanan, uçlara doğru incelen beş ince beyaz çizgi; her biri kendi
/// hızında ve evresinde yavaşça dalgalanır, genlikleri de nefes alır gibi değişir. Saniyede en çok 24 kare; yalnızca
/// birkaç yol çizilir (bulanıklık yok). Pencere önde değilken (başka uygulamaya geçilince) durur, işlemci harcamaz;
/// "Hareketi azalt" açıksa hiç kıpırdamaz.
private struct ListeningWaves: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @Environment(\.controlActiveState) private var activeState: ControlActiveState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || activeState == .inactive)) { (context: TimelineViewDefaultContext) in
            let time: Double = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { (canvas: inout GraphicsContext, size: CGSize) in
                for wave in listeningWaveLines {
                    canvas.stroke(
                        listeningWavePath(wave: wave, size: size, time: time),
                        with: .color(Color.white.opacity(wave.opacity)),
                        style: StrokeStyle(lineWidth: wave.lineWidth, lineCap: .round)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Bir dalga çizgisi: genlik (kart yüksekliğine oranla), dalga sayısı, hız (radyan/sn), evre, kalınlık ve opaklık.
private struct ListeningWaveLine {
    let amplitude: Double
    let cycles: Double
    let speed: Double
    let phase: Double
    let lineWidth: CGFloat
    let opacity: Double
}

private let listeningWaveLines: [ListeningWaveLine] = [
    ListeningWaveLine(amplitude: 0.11, cycles: 1.6, speed: 0.9, phase: 0, lineWidth: 1.6, opacity: 0.75),
    ListeningWaveLine(amplitude: 0.08, cycles: 2.1, speed: -0.7, phase: 1.3, lineWidth: 1.2, opacity: 0.55),
    ListeningWaveLine(amplitude: 0.13, cycles: 1.2, speed: 0.5, phase: 2.6, lineWidth: 1.0, opacity: 0.4),
    ListeningWaveLine(amplitude: 0.06, cycles: 2.8, speed: 1.2, phase: 4.1, lineWidth: 1.0, opacity: 0.45),
    ListeningWaveLine(amplitude: 0.09, cycles: 1.9, speed: -0.4, phase: 5.2, lineWidth: 0.8, opacity: 0.3),
]

/// Dalganın yolu: kartın %44 yüksekliğinde, kenarlarda sıfıra inen (sin² zarf) bir sinüs; genlik zamanla %70–100
/// arasında nefes alır. Saf fonksiyondur.
private func listeningWavePath(wave: ListeningWaveLine, size: CGSize, time: Double) -> Path {
    let midY: Double = size.height * 0.44
    let breath: Double = 0.85 + 0.15 * sin(time * 0.35 + wave.phase)
    let amplitude: Double = wave.amplitude * size.height * breath
    let step: Double = 3
    var path: Path = Path()
    var x: Double = 0
    while x <= size.width {
        let unit: Double = x / max(size.width, 1)
        let envelope: Double = pow(sin(Double.pi * unit), 2)
        let y: Double = midY + amplitude * envelope * sin(unit * wave.cycles * 2 * Double.pi + time * wave.speed + wave.phase)
        if x == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
        x += step
    }
    return path
}

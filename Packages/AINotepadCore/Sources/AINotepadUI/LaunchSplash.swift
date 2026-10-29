import SwiftUI

/// Uygulamanın işareti (simgeyle aynı ölçüler; bkz. `scripts/render-app-icon.swift`): yuvarlak kare üstünde üç çubuk
/// (ses) ve bir çizgi (not). Açık temada siyah kare beyaz işaret, koyuda tersi. Çubuklar ve çizgi dışarıdan verilen
/// durumla açılır (açılış animasyonu).
public struct AppMark: View {
    let size: CGFloat
    /// Çubuklar tam boyunda mı (değilse alçak).
    let barsRaised: Bool
    /// Çizgi uzamış mı.
    let lineDrawn: Bool

    public init(size: CGFloat, barsRaised: Bool, lineDrawn: Bool) {
        self.size = size
        self.barsRaised = barsRaised
        self.lineDrawn = lineDrawn
    }

    public var body: some View {
        let unit: CGFloat = size / 100
        // 100 birimlik ızgarada (x, y, genişlik, yükseklik); işaret yatayda ortalı.
        let bars: [CGRect] = [CGRect(x: 23, y: 40, width: 7, height: 20), CGRect(x: 34, y: 30, width: 7, height: 40), CGRect(x: 45, y: 36, width: 7, height: 28)]
        let line: CGRect = CGRect(x: 57, y: 46.5, width: 20, height: 7)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Theme.primary)
                .shadow(color: .black.opacity(0.18), radius: size * 0.12, y: size * 0.06)
            ForEach(Array(bars.enumerated()), id: \.offset) { (item: (offset: Int, element: CGRect)) in
                Capsule()
                    .fill(Theme.onPrimary)
                    .frame(width: item.element.width * unit, height: item.element.height * unit)
                    .scaleEffect(x: 1, y: barsRaised ? 1 : 0.15, anchor: .center)
                    .animation(.spring(response: 0.45, dampingFraction: 0.5).delay(Double(item.offset) * 0.07), value: barsRaised)
                    .offset(x: item.element.minX * unit, y: item.element.minY * unit)
            }
            Capsule()
                .fill(Theme.onPrimary)
                .frame(width: line.width * unit, height: line.height * unit)
                .scaleEffect(x: lineDrawn ? 1 : 0.01, y: 1, anchor: .leading)
                .animation(.smooth(duration: 0.4), value: lineDrawn)
                .offset(x: line.minX * unit, y: line.minY * unit)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Açılış ekranı (~1,2 sn): işaret bulanıktan netleşerek büyür, çubuklar konuşur gibi yükselir, çizgi soldan uzanır,
/// ad ve slogan aşağıdan belirir; sonra `onFinish`. Tıklayınca hemen geçilir; "Hareketi azalt" açıksa yalnızca kısa
/// bir bekleme. `appName`: işaretin altındaki ürün adı (uygulamanın görünen adı).
public struct LaunchSplash: View {
    let appName: String
    let onFinish: @MainActor () -> Void
    @State private var appeared: Bool = false
    @State private var barsRaised: Bool = false
    @State private var lineDrawn: Bool = false
    @State private var wordsShown: Bool = false
    /// Kapanış: ekran kendi saydamlığıyla söner, sonra animasyonsuz kaldırılır.
    @State private var isFadingOut: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    public init(appName: String, onFinish: @escaping @MainActor () -> Void) {
        self.appName = appName
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 22) {
            AppMark(size: 96, barsRaised: barsRaised, lineDrawn: lineDrawn)
                .scaleEffect(appeared ? 1 : 0.6)
                .blur(radius: appeared ? 0 : 10)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 6) {
                Text(verbatim: appName)
                    .appFont(size: 26, weight: .medium)
                    .tracking(-0.5)
                    .foregroundStyle(Theme.ink)
                Text("Toplantını dinler, notunu yazar.")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            .opacity(wordsShown ? 1 : 0)
            .offset(y: wordsShown ? 0 : 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .opacity(isFadingOut ? 0 : 1)
        .scaleEffect(isFadingOut ? 1.02 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onFinish() }
        .task { await play() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: appName))
    }

    /// Animasyon adımları, sonra sönme. Ekran kendi saydamlığıyla söner ve `onFinish` onu animasyonsuz kaldırır:
    /// kaldırma bir geçiş animasyonuna bırakıldığında, açılışta çalma başlayıp pencere art arda güncellenince geçiş
    /// bitmiyor, açılış ekranı uygulamayı örtüp kalıyordu. Görev iptal edilirse de kapanır.
    private func play() async {
        await playSteps()
        withAnimation(.smooth(duration: 0.45)) { isFadingOut = true }
        _ = await pause(milliseconds: 450)
        onFinish()
    }

    /// Adımları sırayla oynatır; görev iptal edilince kalan adımlar atlanır.
    private func playSteps() async {
        if reduceMotion {
            appeared = true
            barsRaised = true
            lineDrawn = true
            wordsShown = true
            _ = await pause(milliseconds: 500)
            return
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
        guard await pause(milliseconds: 160) else {
            return
        }
        barsRaised = true
        guard await pause(milliseconds: 180) else {
            return
        }
        lineDrawn = true
        withAnimation(.smooth(duration: 0.45)) { wordsShown = true }
        _ = await pause(milliseconds: 900)
    }

    /// Bekler; görev iptal edildiyse false.
    private func pause(milliseconds: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return true
        } catch {
            return false
        }
    }
}

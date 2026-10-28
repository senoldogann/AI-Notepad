import SwiftUI

/// Boş durum kartı: solda yumuşak daire içinde simge, yanında başlık ve (varsa) açıklama. Sayfa içindeki bölümler
/// için (görev yok, not yok…).
public struct EmptyStateCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?

    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey?) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 14) {
            EmptyStateIcon(symbol: symbol, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Alanın ortasında büyük boş durum: simge, başlık, açıklama (liste sütunu gibi tüm alanı kaplayan yerler için).
public struct EmptyStatePlaceholder: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?

    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey?) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            EmptyStateIcon(symbol: symbol, size: 52)
            Text(title)
                .appFont(size: 15, weight: .medium)
                .foregroundStyle(Theme.ink)
            if let message {
                Text(message)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Boş durum simgesi: ince çerçeveli soluk daire içinde vektör simge (SF Symbol).
private struct EmptyStateIcon: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .appFont(size: size * 0.42, weight: .regular)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.muted)
            .frame(width: size, height: size)
            .background(Theme.soft, in: Circle())
            .overlay(Circle().strokeBorder(Theme.line))
            .accessibilityHidden(true)
    }
}

/// Boş sayfanın yol gösteren adımı (ör. "Toplantıyı aç" → "Konuşmacıya ad ver").
public struct EmptyStateStep {
    let symbol: String
    let title: LocalizedStringKey

    public init(symbol: String, title: LocalizedStringKey) {
        self.symbol = symbol
        self.title = title
    }
}

/// Boş sayfanın sahnesi: durgun film gradyanlı küre ve simge; altında başlık, açıklama, yol gösteren adımlar ve
/// eylemler. Sahne açılışta bir kez yumuşakça belirir ("Hareketi azalt" açıksa hemen); sonra hiçbir şey kıpırdamaz.
public struct EmptyStateHero<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let palette: FilmPalette
    let steps: [EmptyStateStep]
    let actions: Actions
    @State private var isShown: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    public init(
        symbol: String, title: LocalizedStringKey, message: LocalizedStringKey, palette: FilmPalette, steps: [EmptyStateStep],
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.palette = palette
        self.steps = steps
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 22) {
            EmptyStateOrb(symbol: symbol, palette: palette)
                .frame(width: 180, height: 170)
                .scaleEffect(isShown ? 1 : 0.94)
                .opacity(isShown ? 1 : 0)
            VStack(spacing: 8) {
                Text(title)
                    .appFont(size: 24, weight: .regular)
                    .tracking(-0.5)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(message)
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460)
            .offset(y: isShown ? 0 : 12)
            .opacity(isShown ? 1 : 0)
            if !steps.isEmpty {
                EmptyStateSteps(steps: steps, palette: palette)
                    .offset(y: isShown ? 0 : 12)
                    .opacity(isShown ? 1 : 0)
            }
            actions
                .offset(y: isShown ? 0 : 12)
                .opacity(isShown ? 1 : 0)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity)
        // Arkada ince, soluk, durgun eğriler (kâğıt dokusu); kenarlara doğru söner. Kaymaz: boş sayfa açık kalırken
        // sürekli çizim yapılmasın.
        .background {
            FlowingLines(seed: "bos-\(symbol)", lineCount: 9, isAnimated: false)
                .mask(RadialGradient(colors: [.black, .clear], center: .center, startRadius: 60, endRadius: 520))
                .padding(-80)
        }
        .onAppear {
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.5)) { isShown = true }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Adımlar: numaralı küçük daireler ve aralarında ince kesik çizgi; sırayla belirir.
private struct EmptyStateSteps: View {
    let steps: [EmptyStateStep]
    let palette: FilmPalette

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { (item: (offset: Int, element: EmptyStateStep)) in
                if item.offset > 0 {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(minWidth: 12, maxWidth: 34)
                        .frame(height: 1)
                        .padding(.top, 17)
                }
                VStack(spacing: 8) {
                    Image(systemName: item.element.symbol)
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(palette.colors.base)
                        .frame(width: 34, height: 34)
                        .background(palette.colors.base.opacity(0.12), in: Circle())
                    Text(item.element.title)
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 110)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sahnenin küresi: durgun film gradyanı (paletin bulutları, grenli doku) daire içinde, arkasında aynı renklerin
/// yumuşak parıltısı; ortada koyu mürekkep simge (pastel zeminde beyaz simge kayboluyordu).
struct EmptyStateOrb: View {
    let symbol: String
    let palette: FilmPalette

    var body: some View {
        ZStack {
            Circle()
                .fill(palette.colors.base.opacity(0.22))
                .frame(width: 150, height: 150)
                .blur(radius: 34)
            FilmGradient(seed: "bos-\(symbol)", palette: palette)
                .frame(width: 116, height: 116)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            Image(systemName: symbol)
                .appFont(size: 38, weight: .medium)
                .foregroundStyle(Color.black.opacity(0.8))
        }
        .accessibilityHidden(true)
    }
}

/// Bir kez, kısa ve sakin konfeti (tüm görevler bitince): paletin renklerinde az sayıda parça yukarı çıkıp düşer.
/// "Hareketi azalt" açıksa çizilmez.
public struct ConfettiBurst: View {
    let palette: FilmPalette
    @State private var start: Date = Date()
    /// Patlama bitti: zaman çizelgesi durur (ekranda kalsa da her karede yeniden çizilmez).
    @State private var isFinished: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    public init(palette: FilmPalette) {
        self.palette = palette
    }

    public var body: some View {
        if !reduceMotion && !isFinished {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isFinished)) { (context: TimelineViewDefaultContext) in
                let elapsed: Double = context.date.timeIntervalSince(start)
                Canvas { (canvas: inout GraphicsContext, size: CGSize) in
                    guard elapsed < 1.8 else {
                        return
                    }
                    let colors: [Color] = [palette.colors.base] + palette.colors.clouds
                    for index in 0..<24 {
                        let seed: Double = Double(index) * 12.9898
                        let angle: Double = -Double.pi / 2 + (fract(sin(seed) * 43758.5453) - 0.5) * 2.2
                        let speed: Double = 180 + fract(sin(seed * 1.7) * 9123.17) * 160
                        let x: Double = size.width / 2 + cos(angle) * speed * elapsed
                        let y: Double = size.height * 0.45 + sin(angle) * speed * elapsed + 420 * elapsed * elapsed
                        let opacity: Double = max(0, 0.85 - elapsed / 1.8)
                        var piece: GraphicsContext = canvas
                        piece.translateBy(x: x, y: y)
                        piece.rotate(by: .radians(elapsed * (4 + Double(index % 5))))
                        piece.opacity = opacity
                        piece.fill(Path(roundedRect: CGRect(x: -4, y: -2, width: 8, height: 4), cornerRadius: 1), with: .color(colors[index % colors.count]))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                start = Date()
                do {
                    try await Task.sleep(for: .seconds(1.9))
                } catch {
                    return
                }
                isFinished = true
            }
        }
    }
}

/// Sayının kesirli kısmı (konfeti için sözde rastgele). Saf fonksiyondur.
private func fract(_ value: Double) -> Double {
    value - value.rounded(.down)
}

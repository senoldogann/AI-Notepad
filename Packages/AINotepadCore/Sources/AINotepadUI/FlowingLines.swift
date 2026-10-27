import SwiftUI

/// Arka planda ince, uzun, çok soluk eğriler (el çizimi gibi): kâğıt dokusu hissi verir, içerikle yarışmaz. Eğriler
/// `seed`'den belirlenir (her açılışta aynı); `isAnimated` ise çok yavaş kayar. Renk temanın mürekkep rengidir.
public struct FlowingLines: View {
    let seed: String
    let lineCount: Int
    let isAnimated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    public init(seed: String, lineCount: Int, isAnimated: Bool) {
        self.seed = seed
        self.lineCount = lineCount
        self.isAnimated = isAnimated
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isAnimated || reduceMotion)) { (context: TimelineViewDefaultContext) in
            let time: Double = isAnimated && !reduceMotion ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas { (canvas: inout GraphicsContext, size: CGSize) in
                let curves: [FlowCurve] = flowCurves(seed: seed, count: lineCount)
                for (index, curve) in curves.enumerated() {
                    let drift: Double = sin(time * 0.05 + Double(index)) * 0.02
                    var path: Path = Path()
                    path.move(to: point(curve.start, size: size, drift: drift))
                    path.addCurve(
                        to: point(curve.end, size: size, drift: -drift),
                        control1: point(curve.control1, size: size, drift: drift * 2),
                        control2: point(curve.control2, size: size, drift: -drift * 2)
                    )
                    canvas.stroke(path, with: .color(Theme.ink.opacity(curve.opacity)), lineWidth: curve.width)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func point(_ unit: CGPoint, size: CGSize, drift: Double) -> CGPoint {
        CGPoint(x: (unit.x + drift) * size.width, y: (unit.y - drift) * size.height)
    }
}

/// Bir eğri: alana göre (0...1, taşabilir) uçlar ve kontrol noktaları, kalınlık ve opaklık.
struct FlowCurve: Equatable {
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint
    let width: CGFloat
    let opacity: Double
}

/// Tohumdan belirlenen eğriler: kenardan kenara uzanan, geniş kavisli çizgiler. Saf fonksiyondur.
func flowCurves(seed: String, count: Int) -> [FlowCurve] {
    var state: UInt64 = seed.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
    func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    return (0..<count).map { (_: Int) -> FlowCurve in
        let fromLeft: Bool = next() < 0.5
        let start: CGPoint = fromLeft ? CGPoint(x: -0.1, y: next() * 1.2 - 0.1) : CGPoint(x: next() * 1.2 - 0.1, y: -0.1)
        let end: CGPoint = fromLeft ? CGPoint(x: 1.1, y: next() * 1.2 - 0.1) : CGPoint(x: next() * 1.2 - 0.1, y: 1.1)
        return FlowCurve(
            start: start,
            control1: CGPoint(x: next() * 1.6 - 0.3, y: next() * 1.6 - 0.3),
            control2: CGPoint(x: next() * 1.6 - 0.3, y: next() * 1.6 - 0.3),
            end: end,
            width: 0.6 + next() * 0.6,
            opacity: 0.05 + next() * 0.05
        )
    }
}

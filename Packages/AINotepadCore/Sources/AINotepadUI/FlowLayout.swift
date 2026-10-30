import SwiftUI

/// Öğeleri satıra dizer, sığmayanı alt satıra geçirir (dar panelde düğmeler taşmasın). Kaptan geniş öğe kap genişliğine
/// daraltılır (uzun başlıklı @ etiketi kesilir, kenardan taşmaz).
public struct FlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    public init(spacing: CGFloat, lineSpacing: CGFloat) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows: [[CGSize]] = arrange(sizes: fittedSizes(subviews: subviews, maxWidth: proposal.width ?? .infinity), maxWidth: proposal.width ?? .infinity)
        let width: CGFloat = rows.map { (row: [CGSize]) -> CGFloat in
            row.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
        }.max() ?? 0
        let height: CGFloat = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes: [CGSize] = fittedSizes(subviews: subviews, maxWidth: bounds.width)
        var origin: CGPoint = bounds.origin
        var rowHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size: CGSize = sizes[index]
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// Öğelerin boyutu: doğal genişliği `maxWidth`'i aşan öğe o genişlikte yeniden ölçülür (yüksekliği daralmış hale
    /// göre).
    private func fittedSizes(subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { (subview: LayoutSubview) -> CGSize in
            let ideal: CGSize = subview.sizeThatFits(.unspecified)
            guard ideal.width > maxWidth else {
                return ideal
            }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }

    /// Boyutları en fazla `maxWidth` genişlikte satırlara böler.
    private func arrange(sizes: [CGSize], maxWidth: CGFloat) -> [[CGSize]] {
        sizes.reduce(into: [[CGSize]]()) { (rows: inout [[CGSize]], size: CGSize) -> Void in
            if let last = rows.last, !last.isEmpty,
               last.map(\.width).reduce(0, +) + spacing * CGFloat(last.count) + size.width <= maxWidth {
                rows[rows.count - 1].append(size)
            } else {
                rows.append([size])
            }
        }
    }
}

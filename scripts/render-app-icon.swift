// Uygulama simgesini çizer: gece mavisi zemin, şampanya altını konuşma balonu; içinde ses dalgası çubukları sağa doğru
// yazı satırlarına dönüşür (ses → not). Zemin tam kare çizilir; macOS köşeleri kendi maskesiyle yuvarlar.
// Kullanım: swift scripts/render-app-icon.swift <çıktı.png>
import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let outputPath: String = CommandLine.arguments[1]

/// sRGB renk.
func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context: CGContext = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Zemin: yukarıdan aşağı gece mavisinden siyaha.
let background: CGGradient = CGGradient(colorsSpace: space, colors: [rgb(30, 38, 72, 1), rgb(9, 12, 24, 1)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Sol üstte yumuşak çivit parıltı.
let glow: CGGradient = CGGradient(colorsSpace: space, colors: [rgb(92, 110, 230, 0.45), rgb(92, 110, 230, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 780), startRadius: 0, endCenter: CGPoint(x: 300, y: 780), endRadius: 560, options: [])

// Altın: açık şampanyadan koyu altına dikey geçiş; çizilen şekle kırpılarak uygulanır.
let gold: CGGradient = CGGradient(colorsSpace: space, colors: [rgb(250, 230, 186, 1), rgb(214, 172, 98, 1), rgb(160, 116, 52, 1)] as CFArray, locations: [0, 0.55, 1])!

/// Yolu altın gradyanla doldurur.
func fillGold(path: CGPath) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gold, start: CGPoint(x: 0, y: 820), end: CGPoint(x: 0, y: 200), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

// Konuşma balonu: yuvarlak dikdörtgen ve sol altta kuyruk tek bir kesintisiz çizgi.
let bubbleRect: CGRect = CGRect(x: 192, y: 300, width: 640, height: 470)
let radius: CGFloat = 150
let stroke: CGFloat = 30
let bubble: CGMutablePath = CGMutablePath()
bubble.move(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.maxY))
bubble.addLine(to: CGPoint(x: bubbleRect.maxX - radius, y: bubbleRect.maxY))
bubble.addArc(tangent1End: CGPoint(x: bubbleRect.maxX, y: bubbleRect.maxY), tangent2End: CGPoint(x: bubbleRect.maxX, y: bubbleRect.minY), radius: radius)
bubble.addArc(tangent1End: CGPoint(x: bubbleRect.maxX, y: bubbleRect.minY), tangent2End: CGPoint(x: bubbleRect.minX, y: bubbleRect.minY), radius: radius)
bubble.addLine(to: CGPoint(x: 462, y: bubbleRect.minY))
bubble.addLine(to: CGPoint(x: 280, y: 196))
bubble.addLine(to: CGPoint(x: 352, y: bubbleRect.minY))
bubble.addArc(tangent1End: CGPoint(x: bubbleRect.minX, y: bubbleRect.minY), tangent2End: CGPoint(x: bubbleRect.minX, y: bubbleRect.maxY), radius: radius)
bubble.addArc(tangent1End: CGPoint(x: bubbleRect.minX, y: bubbleRect.maxY), tangent2End: CGPoint(x: bubbleRect.maxX, y: bubbleRect.maxY), radius: radius)
bubble.closeSubpath()
fillGold(path: bubble.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10))

// İçerik: soldan ses dalgası çubukları, sağa doğru yazı satırları.
let bar: CGFloat = 34
let centerY: CGFloat = bubbleRect.midY
let bars: [(x: CGFloat, height: CGFloat)] = [(300, 110), (362, 220), (424, 300), (486, 170)]
let content: CGMutablePath = CGMutablePath()
for item in bars {
    content.addRoundedRect(in: CGRect(x: item.x - bar / 2, y: centerY - item.height / 2, width: bar, height: item.height), cornerWidth: bar / 2, cornerHeight: bar / 2)
}
let lines: [(y: CGFloat, width: CGFloat)] = [(centerY + 78, 196), (centerY, 160), (centerY - 78, 112)]
for line in lines {
    content.addRoundedRect(in: CGRect(x: 550, y: line.y - bar / 2, width: line.width, height: bar), cornerWidth: bar / 2, cornerHeight: bar / 2)
}
fillGold(path: content)

let image: CGImage = context.makeImage()!
let data: Data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: outputPath))
print("Yazıldı: \(outputPath)")

// Uygulama simgesini çizer (ElevenLabs sadeliğinde): neredeyse siyah zemin, çok hafif kumlu doku; beyaz üç yuvarlak
// çubuk sesi, sağdaki yatay çizgi notu anlatır (ses → not). Zemin tam kare çizilir; macOS köşeleri kendi maskesiyle
// yuvarlar. Açılış ekranındaki işaret (`AppMark`) aynı ölçüleri kullanır.
// Kullanım: swift scripts/render-app-icon.swift <çıktı.png>
import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let unit: CGFloat = size / 100
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

// Zemin: yukarıdan aşağı koyu griden siyaha.
let background: CGGradient = CGGradient(colorsSpace: space, colors: [rgb(34, 34, 34, 1), rgb(6, 6, 6, 1)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Üstte çok hafif ışık (cam gibi derinlik).
let glow: CGGradient = CGGradient(colorsSpace: space, colors: [rgb(255, 255, 255, 0.07), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: size * 0.3, y: size * 0.95), startRadius: 0, endCenter: CGPoint(x: size * 0.3, y: size * 0.95), endRadius: size * 0.9, options: [])

// İnce kumlu doku: sabit tohumlu noktalar (her çizimde aynı).
var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
for _ in 0..<60000 {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    let x: CGFloat = CGFloat(seed >> 40) / CGFloat(1 << 24) * size
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    let y: CGFloat = CGFloat(seed >> 40) / CGFloat(1 << 24) * size
    context.setFillColor(seed & 1 == 0 ? rgb(255, 255, 255, 0.035) : rgb(0, 0, 0, 0.12))
    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
}

// İşaret (100 birimlik ızgarada, y yukarı): üç çubuk ve bir çizgi; yatayda ortalanır.
let marks: [CGRect] = [
    CGRect(x: 24, y: 40, width: 7, height: 20),
    CGRect(x: 35, y: 30, width: 7, height: 40),
    CGRect(x: 46, y: 36, width: 7, height: 28),
    CGRect(x: 58, y: 46.5, width: 20, height: 7),
]
let shift: CGFloat = 50 - (24 + 78) / 2
context.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: rgb(0, 0, 0, 0.45))
context.setFillColor(rgb(250, 250, 250, 1))
for mark in marks {
    let rect: CGRect = CGRect(x: (mark.minX + shift) * unit, y: (100 - mark.maxY) * unit, width: mark.width * unit, height: mark.height * unit)
    let radius: CGFloat = min(rect.width, rect.height) / 2
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

let image: CGImage = context.makeImage()!
let data: Data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: outputPath))
print("Yazıldı: \(outputPath)")

// Uygulama simgesini çizer (ElevenLabs sadeliğinde): neredeyse siyah zemin, çok hafif kumlu doku; beyaz üç yuvarlak
// çubuk sesi, sağdaki yatay çizgi notu anlatır (ses → not). Apple'ın macOS simge ızgarasına uyar: 1024'lük tuvalde
// 824'lük yuvarlak köşeli gövde, çevresinde saydam pay ve hafif gölge. Tam kare (kenara taşan) simgeyi macOS 26
// standart şekil saymaz, küçültüp gri bir çerçeveye koyar (Dock'ta logo görünmez olur). Açılış ekranındaki işaret
// (`AppMark`) aynı ölçüleri kullanır.
// Kullanım: swift scripts/render-app-icon.swift <çıktı.png> <mac|ios>
// ios: iPhone simgesi kenara kadar kare ve saydamlık kanalı olmadan çizilir (iOS köşeleri kendi maskesiyle yuvarlar;
// App Store Connect saydamlık kanallı simgeyi reddeder, ITMS-90717).
import AppKit
import CoreGraphics
import Foundation

/// Komut satırı: çıktı dosyası ve platform (yalnızca `mac` ya da `ios`; başka değer sessizce macOS simgesine dönmez).
guard CommandLine.arguments.count == 3, ["mac", "ios"].contains(CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("Kullanım: swift scripts/render-app-icon.swift <çıktı.png> <mac|ios>\n".utf8))
    exit(1)
}

let canvas: CGFloat = 1024
let isIOS: Bool = CommandLine.arguments[2] == "ios"
/// Gövde: Apple'ın macOS ızgarasında 824×824, her yanda 100 pt saydam pay; köşe yarıçapı gövdenin ~%22,4'ü. iOS'ta tam
/// kare.
let body: CGRect = isIOS ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = isIOS ? 0 : 185
let size: CGFloat = body.width
let unit: CGFloat = size / 100
let outputPath: String = CommandLine.arguments[1]

/// sRGB renk.
func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
/// macOS simgesinin saydam payı ve gölgesi için saydamlık kanalı gerekir; iOS simgesi opak (kanal yok).
let alphaInfo: CGImageAlphaInfo = isIOS ? .noneSkipLast : .premultipliedLast
let context: CGContext = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: alphaInfo.rawValue
)!
let bodyPath: CGPath = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Gövdenin altında hafif gölge (macOS simgeleri gibi).
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0, 0, 0, 0.32))
context.addPath(bodyPath)
context.setFillColor(rgb(6, 6, 6, 1))
context.fillPath()
context.restoreGState()

// Sonraki her şey gövdenin içine, gövdenin sol alt köşesi başlangıç olacak şekilde çizilir.
context.addPath(bodyPath)
context.clip()
context.translateBy(x: body.minX, y: body.minY)

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

// DMG penceresinin arka planını çizer (tasarım yönü C): kırık beyaz zemin, altta durgun pastel film gradyanı (şeftali
// → lavanta), ince gren; üstte ürün adı ve kısa kurulum cümlesi, iki simge yuvası arasında ince, hareket izi
// bırakan bir ok. Simge yuvalarının yerleri `scripts/make-dmg.sh`teki Finder konumlarıyla aynıdır (değişirse ikisi
// birlikte değişir).
// Kullanım: swift scripts/render-dmg-background.swift <ürün-adı> <çıktı-klasörü>
// Çıktı: background.png (660×420) ve background@2x.png (1320×840). Config/DMG/ altındaki dosyalar bu betikle
// üretilmiştir (ürün adı değişirse yalnızca yeniden çizilir):
//   swift scripts/render-dmg-background.swift "AI-Notepad" Config/DMG
import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Pencere içeriğinin boyutu (nokta). Finder pencere sınırları bu boyuta ayarlanır.
let canvasWidth: CGFloat = 660
let canvasHeight: CGFloat = 420
/// Simge yuvalarının merkezleri (üst-sol başlangıçlı nokta). make-dmg.sh'teki konumlarla aynı.
let appSlot: CGPoint = CGPoint(x: 170, y: 200)
let applicationsSlot: CGPoint = CGPoint(x: 490, y: 200)

/// Komut satırı: ürün adı (pencerenin üstünde yazar) ve çıktı klasörü.
guard CommandLine.arguments.count == 3, !CommandLine.arguments[1].isEmpty else {
    FileHandle.standardError.write(Data("Kullanım: swift scripts/render-dmg-background.swift <ürün-adı> <çıktı-klasörü>\n".utf8))
    exit(1)
}
let productName: String = CommandLine.arguments[1]
let outputDirectory: URL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

/// Çizim hatası: ne yapılamadığını ve hangi dosyanın etkilendiğini söyler.
enum RenderError: Error, CustomStringConvertible {
    case fontRegistration(path: String, reason: String)
    case fontMissing(requested: String, resolved: String)
    case textTooWide(text: String, width: CGFloat, limit: CGFloat)
    case contextCreation(scale: Int)
    case imageEncoding(path: String)

    var description: String {
        switch self {
        case .fontRegistration(let path, let reason): "Yazı tipi kaydedilemedi (\(path)): \(reason)"
        case .fontMissing(let requested, let resolved): "Yazı tipi bulunamadı: \(requested) istendi, \(resolved) geldi"
        case .textTooWide(let text, let width, let limit): "Metin pencereye sığmıyor: \"\(text)\" \(Int(width)) pt, en çok \(Int(limit)) pt"
        case .contextCreation(let scale): "\(scale)x çizim bağlamı oluşturulamadı"
        case .imageEncoding(let path): "PNG kodlanamadı: \(path)"
        }
    }
}

/// sRGB renk (0...255 bileşenler).
func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// Uygulamanın paketlediği Inter'i yalnızca bu süreç için kaydeder (sistemde kurulu olması gerekmez).
func registerInter() throws {
    let fontURL: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Fonts/InterVariable.ttf")
    var error: Unmanaged<CFError>?
    guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error) else {
        let reason: String = error.map { String(describing: $0.takeRetainedValue()) } ?? "bilinmeyen neden"
        throw RenderError.fontRegistration(path: fontURL.path, reason: reason)
    }
}

/// Inter'in adlandırılmış örneği (ör. "InterVariable-SemiBold"). CoreText bulamazsa sessizce Helvetica verir; bu
/// yüzden çözülen ad denetlenir.
func interFont(postScriptName: String, size: CGFloat) throws -> CTFont {
    let font: CTFont = CTFontCreateWithName(postScriptName as CFString, size, nil)
    let resolved: String = CTFontCopyPostScriptName(font) as String
    guard resolved == postScriptName else { throw RenderError.fontMissing(requested: postScriptName, resolved: resolved) }
    return font
}

/// Yumuşak, Gauss benzeri düşen ışık lekesi: merkezde verilen saydamlık, kenarda sıfır (bulanıklık filtresi gerekmez).
func drawGlow(_ context: CGContext, center: CGPoint, radius: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    let falloff: [CGFloat] = [1, 0.86, 0.62, 0.38, 0.18, 0.06, 0]
    let locations: [CGFloat] = [0, 0.16, 0.33, 0.5, 0.67, 0.84, 1]
    let colors: [CGColor] = falloff.map { (level: CGFloat) -> CGColor in rgb(red, green, blue, alpha * level) }
    let gradient: CGGradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// Ortalanmış tek satır metin; `baseline` üst-sol başlangıçlı nokta cinsinden taban çizgisidir. Kenarlarda en az 40 pt
/// boşluk kalmazsa (uzun ürün adı) kırpılmış görüntü yerine hata verir.
func drawCenteredText(_ context: CGContext, text: String, font: CTFont, color: CGColor, kerning: CGFloat, baseline: CGFloat) throws {
    let attributed: NSAttributedString = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): kerning,
    ])
    let line: CTLine = CTLineCreateWithAttributedString(attributed)
    let width: CGFloat = CTLineGetTypographicBounds(line, nil, nil, nil)
    let limit: CGFloat = canvasWidth - 80
    guard width <= limit else { throw RenderError.textTooWide(text: text, width: width, limit: limit) }
    context.textPosition = CGPoint(x: (canvasWidth - width) / 2, y: canvasHeight - baseline)
    CTLineDraw(line, context)
}

/// İnce film greni: piksel başına sabit tohumlu gri gürültü, overlay ile (beyaz zeminde görünmez, pastelde dokulu).
func drawGrain(_ context: CGContext, pixelWidth: Int, pixelHeight: Int) {
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    var pixels: [UInt8] = [UInt8](repeating: 0, count: pixelWidth * pixelHeight)
    for index in 0..<pixels.count {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        pixels[index] = UInt8(truncatingIfNeeded: 128 + Int(state % 81) - 40)
    }
    let provider: CGDataProvider = CGDataProvider(data: Data(pixels) as CFData)!
    let grain: CGImage = CGImage(
        width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: pixelWidth,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
    context.saveGState()
    context.setBlendMode(.overlay)
    context.setAlpha(0.32)
    context.interpolationQuality = .none
    context.draw(grain, in: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    context.restoreGState()
}

/// İki yuva arasındaki ok: kuyruğu saydamdan başlayıp başa doğru belirginleşen, hafif yay çizen ince çizgi (hareket
/// izi) ve ince, yuvarlak uçlu bir ok başı. Renk şeftaliden lavantaya geçer.
func drawArrow(_ context: CGContext) {
    let y: CGFloat = canvasHeight - appSlot.y
    let start: CGPoint = CGPoint(x: appSlot.x + 98, y: y)
    let end: CGPoint = CGPoint(x: applicationsSlot.x - 98, y: y)
    let control: CGPoint = CGPoint(x: (start.x + end.x) / 2, y: y + 14)
    let curve: CGMutablePath = CGMutablePath()
    curve.move(to: start)
    curve.addQuadCurve(to: end, control: control)
    // Ok başı, eğrinin uçtaki teğetine göre döndürülür.
    let angle: CGFloat = atan2(end.y - control.y, end.x - control.x)
    let headLength: CGFloat = 10
    let spread: CGFloat = .pi / 5.2
    let head: CGMutablePath = CGMutablePath()
    head.move(to: CGPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread)))
    head.addLine(to: end)
    head.addLine(to: CGPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread)))
    let stroke: CGPath = curve.copy(strokingWithWidth: 1.6, lineCap: .round, lineJoin: .round, miterLimit: 1)
    let headStroke: CGPath = head.copy(strokingWithWidth: 1.6, lineCap: .round, lineJoin: .round, miterLimit: 1)
    let colors: [CGColor] = [rgb(233, 137, 106, 0), rgb(233, 137, 106, 0.55), rgb(176, 140, 214, 0.95), rgb(150, 118, 204, 1)]
    let gradient: CGGradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.35, 0.8, 1])!
    context.saveGState()
    context.addPath(stroke)
    context.addPath(headStroke)
    context.clip()
    context.drawLinearGradient(gradient, start: CGPoint(x: start.x, y: y), end: CGPoint(x: end.x, y: y), options: [.drawsAfterEndLocation])
    context.restoreGState()
    // Kuyrukta, harekete eşlik eden üç küçük, giderek silikleşen nokta.
    for (index, alpha) in [0.42, 0.26, 0.12].enumerated() {
        let x: CGFloat = start.x - 9 - CGFloat(index) * 8
        let radius: CGFloat = 1.3 - CGFloat(index) * 0.25
        context.setFillColor(rgb(233, 137, 106, alpha))
        context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }
}

/// Arka planı verilen ölçekte çizip PNG olarak yazar.
func render(scale: Int, fileName: String) throws {
    let pixelWidth: Int = Int(canvasWidth) * scale
    let pixelHeight: Int = Int(canvasHeight) * scale
    guard let context: CGContext = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw RenderError.contextCreation(scale: scale) }
    // Bundan sonra her şey nokta cinsinden, sol alt başlangıçlı (CoreGraphics) çizilir.
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    // Zemin: uygulamanın kırık beyazı (#FDFCFC).
    context.setFillColor(rgb(253, 252, 252, 1))
    context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

    // Pastel film gradyanı: alt yarıda şeftali/mercan solda, lavanta sağda, ortada krem ışık (uygulamanın "sunset"
    // ve "violet" aileleri).
    drawGlow(context, center: CGPoint(x: 120, y: 70), radius: 330, red: 247, green: 205, blue: 184, alpha: 0.85)
    drawGlow(context, center: CGPoint(x: 30, y: -20), radius: 260, red: 240, green: 174, blue: 146, alpha: 0.55)
    drawGlow(context, center: CGPoint(x: 560, y: 80), radius: 340, red: 201, green: 163, blue: 224, alpha: 0.6)
    drawGlow(context, center: CGPoint(x: 660, y: -10), radius: 260, red: 222, green: 209, blue: 245, alpha: 0.7)
    drawGlow(context, center: CGPoint(x: 340, y: 40), radius: 220, red: 244, green: 192, blue: 168, alpha: 0.35)
    drawGlow(context, center: CGPoint(x: 330, y: 230), radius: 260, red: 255, green: 243, blue: 230, alpha: 0.55)

    // Üst kısım temiz kalsın: başlık kırık beyaz zeminde okunur, gradyan aşağıya doğru belirir.
    let fade: CGGradient = CGGradient(
        colorsSpace: space,
        colors: [rgb(253, 252, 252, 1), rgb(253, 252, 252, 0.85), rgb(253, 252, 252, 0)] as CFArray,
        locations: [0, 0.45, 1]
    )!
    context.drawLinearGradient(fade, start: CGPoint(x: 0, y: canvasHeight), end: CGPoint(x: 0, y: canvasHeight - 250), options: [])

    drawGrain(context, pixelWidth: pixelWidth, pixelHeight: pixelHeight)

    // Simge yuvalarının arkasında yumuşak beyaz ışık: simgeler gradyandan ayrılır, etiketler okunur kalır.
    for slot in [appSlot, applicationsSlot] {
        drawGlow(context, center: CGPoint(x: slot.x, y: canvasHeight - slot.y - 8), radius: 120, red: 255, green: 255, blue: 255, alpha: 0.75)
    }

    drawArrow(context)

    // Başlık ve kurulum cümlesi.
    try drawCenteredText(context, text: productName, font: try interFont(postScriptName: "InterVariable-SemiBold", size: 22), color: rgb(10, 10, 10, 0.92), kerning: -0.35, baseline: 62)
    try drawCenteredText(context, text: "Drag to Applications to install", font: try interFont(postScriptName: "InterVariable", size: 13), color: rgb(115, 115, 115, 1), kerning: 0, baseline: 86)

    let image: CGImage = context.makeImage()!
    let representation: NSBitmapImageRep = NSBitmapImageRep(cgImage: image)
    // 2x görüntü 144 dpi olarak işaretlenir: nokta boyutu 1x ile aynı kalır.
    representation.size = NSSize(width: canvasWidth, height: canvasHeight)
    let path: String = outputDirectory.appendingPathComponent(fileName).path
    guard let data: Data = representation.representation(using: .png, properties: [:]) else { throw RenderError.imageEncoding(path: path) }
    try data.write(to: URL(fileURLWithPath: path))
    print("Yazıldı: \(path)")
}

do {
    try registerInter()
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try render(scale: 1, fileName: "background.png")
    try render(scale: 2, fileName: "background@2x.png")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

// Yazdırılabilir belge ve PDF (AppKit metin çizimi) yalnızca macOS'ta; iPhone'da web sayfası paylaşılır.
#if os(macOS)
import AINotepadCore
import AppKit

/// PDF sayfası: A4, kenar boşlukları.
private let pageSize: CGSize = CGSize(width: 595, height: 842)
private let pageMargin: CGFloat = 56
private let footerHeight: CGFloat = 24

/// Toplantının yazdırılabilir belgesi: başlık, tarih, senin görevlerin, özet, kararlar, diğer görevler, sözlük
/// ve paragraflı transkript (Türkçesiyle). Saf fonksiyondur.
public func meetingDocument(record: MeetingRecord) -> NSAttributedString {
    let document: NSMutableAttributedString = NSMutableAttributedString()
    document.append(styled(text: (record.note?.title ?? record.title) + "\n", style: .title))
    document.append(styled(text: meetingMetaLine(record: record) + "\n", style: .meta))
    if let note = record.note {
        let mine: [NoteTask] = note.tasks.filter(\.isMine)
        let others: [NoteTask] = note.tasks.filter { !$0.isMine }
        if !mine.isEmpty {
            document.append(styled(text: String(localized: "SENİN GÖREVLERİN") + "\n", style: .heading))
            mine.forEach { document.append(taskParagraph(task: $0)) }
        } else {
            document.append(styled(text: String(localized: "SENİN GÖREVLERİN") + "\n", style: .heading))
            document.append(styled(text: String(localized: "Sana düşen görev yok.") + "\n", style: .listItemMuted))
        }
        document.append(styled(text: String(localized: "ÖZET") + "\n", style: .heading))
        document.append(styled(text: note.summary + "\n", style: .body))
        if !note.decisions.isEmpty {
            document.append(styled(text: String(localized: "KARARLAR") + "\n", style: .heading))
            note.decisions.forEach { document.append(styled(text: "•  \($0)\n", style: .listItem)) }
        }
        if !others.isEmpty {
            document.append(styled(text: String(localized: "DİĞER GÖREVLER") + "\n", style: .heading))
            others.forEach { document.append(taskParagraph(task: $0)) }
        }
        if !note.glossary.isEmpty {
            document.append(styled(text: String(localized: "SÖZLÜK") + "\n", style: .heading))
            for entry in note.glossary {
                document.append(styled(text: entry.term, style: .listItemStrong))
                document.append(styled(text: " — \(entry.meaning)\n", style: .listItem))
            }
        }
    }
    let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: record)
    if !paragraphs.isEmpty {
        document.append(styled(text: String(localized: "TRANSKRİPT") + "\n", style: .heading))
        for paragraph in paragraphs {
            document.append(styled(text: "\(timestamp(seconds: paragraph.startSec))  ", style: .transcriptTime))
            document.append(styled(text: paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames) + "\n", style: .transcriptLabel))
            document.append(styled(text: paragraph.text + "\n", style: paragraph.turkish == nil ? .transcriptText : .transcriptTextBeforeTurkish))
            if let turkish = paragraph.turkish {
                document.append(styled(text: turkish + "\n", style: .transcriptTurkish))
            }
        }
    }
    return document
}

/// Belgeyi A4 sayfalara dizip PDF verisi üretir; her sayfanın altında "Sayfa N / M".
@MainActor
public func meetingPDF(record: MeetingRecord) throws -> Data {
    let storage: NSTextStorage = NSTextStorage(attributedString: meetingDocument(record: record))
    let layout: NSLayoutManager = NSLayoutManager()
    storage.addLayoutManager(layout)
    let textSize: CGSize = CGSize(width: pageSize.width - 2 * pageMargin, height: pageSize.height - 2 * pageMargin - footerHeight)
    var containers: [NSTextContainer] = []
    // Tüm metin yerleşene kadar sayfa (metin kabı) ekle.
    repeat {
        let container: NSTextContainer = NSTextContainer(size: textSize)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        containers.append(container)
        layout.ensureLayout(for: container)
    } while NSMaxRange(layout.glyphRange(for: containers[containers.count - 1])) < layout.numberOfGlyphs

    let data: NSMutableData = NSMutableData()
    var mediaBox: CGRect = CGRect(origin: .zero, size: pageSize)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        throw StorageError.writeFailed(path: "\(record.id).pdf", reason: "PDF bağlamı oluşturulamadı")
    }
    let graphics: NSGraphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
    for (index, container) in containers.enumerated() {
        context.beginPDFPage(nil)
        // AppKit metni üstten alta çizer: sayfa ters çevrilir.
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let range: NSRange = layout.glyphRange(for: container)
        let origin: CGPoint = CGPoint(x: pageMargin, y: pageMargin)
        layout.drawBackground(forGlyphRange: range, at: origin)
        layout.drawGlyphs(forGlyphRange: range, at: origin)
        let footer: NSAttributedString = styled(text: String(localized: "Sayfa \(index + 1) / \(containers.count)"), style: .footer)
        footer.draw(at: CGPoint(x: (pageSize.width - footer.size().width) / 2, y: pageSize.height - pageMargin))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

private func taskParagraph(task: NoteTask) -> NSAttributedString {
    let line: NSMutableAttributedString = NSMutableAttributedString()
    line.append(styled(text: "☐  ", style: .listItem))
    line.append(styled(text: task.owner, style: .listItemStrong))
    line.append(styled(text: " — \(task.description)", style: .listItem))
    if let due = task.dueDate {
        line.append(styled(text: "  (\(due))", style: .listItemMuted))
    }
    line.append(styled(text: "\n", style: .listItem))
    return line
}

/// Belgedeki metin biçimleri.
private enum DocumentStyle {
    case title
    case meta
    case heading
    case body
    case listItem
    case listItemStrong
    case listItemMuted
    case transcriptTime
    case transcriptLabel
    case transcriptText
    case transcriptTextBeforeTurkish
    case transcriptTurkish
    case footer
}

/// Belge yazı tipinin ağırlığı.
private enum DocumentWeight {
    case regular
    case semibold
    case italic
}

/// Helvetica Neue: sistem yazı tipi (SF) PDF'e gömülünce metin kopyalama/aramada harfler bozuk çıkıyor
/// ("Aino" → "A$no"); Helvetica Neue her Mac'te var ve PDF'te doğru metin verir.
private func documentFont(size: CGFloat, weight: DocumentWeight) -> NSFont {
    let name: String = switch weight {
    case .regular: "HelveticaNeue"
    case .semibold: "HelveticaNeue-Medium"
    case .italic: "HelveticaNeue-Italic"
    }
    guard let font = NSFont(name: name, size: size) else {
        preconditionFailure("macOS'ta yerleşik yazı tipi bulunamadı: \(name)")
    }
    return font
}

private func styled(text: String, style: DocumentStyle) -> NSAttributedString {
    let paragraph: NSMutableParagraphStyle = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    let accent: NSColor = NSColor(srgbRed: 0x3B / 255, green: 0x5B / 255, blue: 0xDB / 255, alpha: 1)
    let muted: NSColor = NSColor(white: 0.42, alpha: 1)
    let ink: NSColor = NSColor(white: 0.1, alpha: 1)
    let font: NSFont
    var color: NSColor = ink
    var kern: CGFloat = 0
    switch style {
    case .title:
        font = documentFont(size: 22, weight: .semibold)
        paragraph.paragraphSpacing = 4
    case .meta:
        font = documentFont(size: 10.5, weight: .regular)
        color = muted
        paragraph.paragraphSpacing = 18
    case .heading:
        font = documentFont(size: 10, weight: .semibold)
        color = accent
        kern = 0.8
        paragraph.paragraphSpacingBefore = 16
        paragraph.paragraphSpacing = 6
    case .body:
        font = documentFont(size: 11.5, weight: .regular)
        paragraph.lineSpacing = 3
    case .listItem:
        font = documentFont(size: 11.5, weight: .regular)
        paragraph.headIndent = 16
        paragraph.paragraphSpacing = 4
    case .listItemStrong:
        font = documentFont(size: 11.5, weight: .semibold)
        paragraph.headIndent = 16
        paragraph.paragraphSpacing = 4
    case .listItemMuted:
        font = documentFont(size: 10.5, weight: .regular)
        color = muted
        paragraph.headIndent = 16
    case .transcriptTime:
        font = documentFont(size: 9.5, weight: .regular)
        color = muted
        paragraph.paragraphSpacingBefore = 8
    case .transcriptLabel:
        font = documentFont(size: 9.5, weight: .semibold)
        color = muted
        kern = 0.4
        paragraph.paragraphSpacingBefore = 8
    case .transcriptText:
        font = documentFont(size: 11, weight: .regular)
        paragraph.lineSpacing = 2.5
    case .transcriptTextBeforeTurkish:
        font = documentFont(size: 11, weight: .regular)
        paragraph.lineSpacing = 2.5
        paragraph.paragraphSpacing = 2
    case .transcriptTurkish:
        font = documentFont(size: 10.5, weight: .italic)
        color = muted
        paragraph.lineSpacing = 2
    case .footer:
        font = documentFont(size: 9, weight: .regular)
        color = muted
    }
    return NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: color,
        .kern: kern,
        .paragraphStyle: paragraph,
    ])
}
#endif

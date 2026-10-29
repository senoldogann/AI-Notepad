// Verilen sürecin ekrandaki pencerelerini listeler (scripts/make-screenshots.sh kullanır): her satırda pencere
// numarası, katman, genişlik ve yükseklik (nokta), sekmeyle ayrılmış. Yalnızca o sürecin pencereleri yazılır; başka
// uygulamaların pencerelerine bakılmaz.
// Kullanım: swift scripts/demo-windows.swift <pid>
import CoreGraphics
import Foundation

/// Bir pencerenin listede yazılan bilgileri.
struct WindowLine {
    let number: Int
    let layer: Int
    let width: Int
    let height: Int
}

/// Komut satırındaki süreç numarası; geçersizse açıklamayla çıkar.
func requestedPID(arguments: [String]) -> Int32 {
    guard arguments.count == 2, let pid = Int32(arguments[1]), pid > 0 else {
        FileHandle.standardError.write(Data("kullanım: swift scripts/demo-windows.swift <pid>\n".utf8))
        exit(2)
    }
    return pid
}

/// Sürecin ekranda görünen pencereleri. Saf olmayan tek adım pencere listesinin okunmasıdır.
func windows(pid: Int32) -> [WindowLine] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: AnyObject]] else {
        FileHandle.standardError.write(Data("pencere listesi okunamadı (CGWindowListCopyWindowInfo nil döndü)\n".utf8))
        exit(1)
    }
    return list.compactMap { (info: [String: AnyObject]) -> WindowLine? in
        guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
              let number = info[kCGWindowNumber as String] as? Int,
              let layer = info[kCGWindowLayer as String] as? Int,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else {
            return nil
        }
        return WindowLine(number: number, layer: layer, width: Int(bounds.width), height: Int(bounds.height))
    }
}

for line in windows(pid: requestedPID(arguments: CommandLine.arguments)) {
    print("\(line.number)\t\(line.layer)\t\(line.width)\t\(line.height)")
}

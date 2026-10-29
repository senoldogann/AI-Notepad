import Foundation

/// Penceredeki hata şeridinin en çok gösterdiği hata.
public let visibleErrorLimit: Int = 3

/// Hata şeridinde gösterilecek hatalar: aynı ekranda başka yerde zaten görünenler (başlat düğmesinin yanındaki
/// neden, kurulum eksikleri) ve çözülmüş durumların hataları (ör. giriş yapıldıktan sonra "giriş yapılmamış")
/// gösterilmez; tekrarlar bir kez, en yeni `visibleErrorLimit` tanesi kalır (eskiden yeniye). Saf fonksiyondur.
public func visibleErrorMessages(errors: [String], shownElsewhere: [String], resolved: [String]) -> [String] {
    let hidden: Set<String> = Set(shownElsewhere + resolved)
    var seen: Set<String> = []
    var result: [String] = []
    for message in errors.reversed() where !hidden.contains(message) && !seen.contains(message) {
        seen.insert(message)
        result.append(message)
        if result.count == visibleErrorLimit {
            break
        }
    }
    return result.reversed()
}

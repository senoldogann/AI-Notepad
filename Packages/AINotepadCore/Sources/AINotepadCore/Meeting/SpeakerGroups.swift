import Foundation

/// Konuşmacıların gösterimi: ayrı gösterilenler ve tek "Kısa konuşmalar (N)" girişinde toplananlar.
///
/// Konuşmacı ayırma kısa araya girmeleri ya da yabancı dilde klipleri ayrı kişi sayabiliyor (18 dakikalık haber
/// yayınında 12 "Konuşmacı"). Konuşma kimseye yeniden atanmaz ve birleştirilmez (yanlış kişi, görevi yanlış kişiye
/// yazdırırdı): yalnızca toplantı sayfasındaki çipler, konuşma payı ve konuşmacı sayısı sadeleşir; transkriptte her
/// bölüm kendi etiketiyle kalır.
public struct SpeakerGroups: Sendable, Equatable {
    /// Ayrı gösterilen konuşmacılar (çok konuşandan aza).
    public let major: [SpeakerShare]
    /// "Kısa konuşmalar"da toplananlar (çok konuşandan aza); en az `minorSpeakerMinCount` tane yoksa boş.
    public let minor: [SpeakerShare]

    public init(major: [SpeakerShare], minor: [SpeakerShare]) {
        self.major = major
        self.minor = minor
    }

    /// Kısa konuşmaların toplam süresi (saniye).
    public var minorSeconds: Double {
        minor.map(\.seconds).reduce(0, +)
    }

    /// Kısa konuşmaların toplamdaki payı (0...1).
    public var minorFraction: Double {
        minor.map(\.fraction).reduce(0, +)
    }
}

/// Kısa konuşmacı: toplam konuşması bundan kısa (saniye)…
let minorSpeakerMaxSec: Double = 15
/// …ve toplam konuşmadaki payı bundan küçük. İkisi birden gerekir: kısa toplantıda (5 dk) sınır payla ~9 sn'ye iner,
/// uzun toplantıda (1 saat) 15 sn'de kalır; 15 sn'den uzun konuşan kimse toplanmaz.
let minorSpeakerMaxFraction: Double = 0.03
/// En az bu kadar kısa konuşmacı varsa toplanır: tek kişi için "Kısa konuşmalar (1)" girişi sadeleştirmez.
let minorSpeakerMinCount: Int = 2

/// Konuşmacı kısa mı (bkz. `minorSpeakerMaxSec`, `minorSpeakerMaxFraction`). "Sen", ayrılmamış "Diğerleri" ve kullanıcının
/// ad verdiği kişi hiçbir zaman kısa değildir. Saf fonksiyondur.
public func isMinorSpeaker(share: SpeakerShare, speakerNames: [Int: String]) -> Bool {
    guard share.key.speaker == .others, let person = share.key.person, (speakerNames[person] ?? "").isEmpty else {
        return false
    }
    return share.seconds < minorSpeakerMaxSec && share.fraction < minorSpeakerMaxFraction
}

/// Konuşma paylarını ayrı gösterilenler ve kısa konuşmalar olarak ayırır (sıra korunur); kısa konuşmacı
/// `minorSpeakerMinCount`'tan azsa hepsi ayrı gösterilir. Saf fonksiyondur.
public func groupedSpeakers(shares: [SpeakerShare], speakerNames: [Int: String]) -> SpeakerGroups {
    let minor: [SpeakerShare] = shares.filter { isMinorSpeaker(share: $0, speakerNames: speakerNames) }
    guard minor.count >= minorSpeakerMinCount else {
        return SpeakerGroups(major: shares, minor: [])
    }
    return SpeakerGroups(major: shares.filter { !isMinorSpeaker(share: $0, speakerNames: speakerNames) }, minor: minor)
}

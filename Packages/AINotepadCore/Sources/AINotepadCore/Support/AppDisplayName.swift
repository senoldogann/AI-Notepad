import Foundation

/// Uygulamanın görünen adı okunamadı (derleme yapılandırması hatası: hedefin `INFOPLIST_KEY_CFBundleDisplayName`'i).
public enum AppDisplayNameError: Error, Equatable {
    /// Paketin Info.plist'inde `CFBundleDisplayName` yok ya da boş.
    case missing(bundle: String)
}

/// Paketin kullanıcıya görünen adı (Info.plist `CFBundleDisplayName`, yerelleştirilmiş değer): geliştirici sürümü ve
/// iPhone "AI-Notepad", abonelik sürümü "Gistsmith". Arayüz ve mesaj metinleri ürün adını buradan alır; paket (Core/UI)
/// adı hiçbir zaman kendisi okumaz, parametre olarak alır. Ad yoksa ya da boşsa `AppDisplayNameError.missing`
/// (tahmin edilmez).
public func appDisplayName(bundle: Bundle) throws -> String {
    guard let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
          !name.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw AppDisplayNameError.missing(bundle: bundle.bundleIdentifier ?? bundle.bundlePath)
    }
    return name
}

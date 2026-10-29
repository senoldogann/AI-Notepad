import AINotepadCore
import Foundation
import os

private let appNameLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "App")

/// Uygulamanın görünen adı, tek kaynak: hedefin Info.plist'indeki `CFBundleDisplayName` (geliştirici sürümü ve iPhone
/// "AI-Notepad", abonelik sürümü "Gistsmith"; bkz. project.yml). Arayüz metinleri ve paketin metin kuran fonksiyonları
/// adı buradan alır. İlk kullanımda bir kez okunur; yoksa uygulama açılmaz (yanlış adla metin gösterilmez). Mac'te
/// `AppEntry.main` açılışta okur. Mac ve iPhone hedefleri bu dosyayı paylaşır.
let appName: String = {
    do {
        return try appDisplayName(bundle: .main)
    } catch {
        appNameLogger.fault("Uygulamanın görünen adı tanımlı değil, uygulama açılmıyor, hata: \(String(describing: error), privacy: .private)")
        fatalError("Uygulamanın görünen adı tanımlı değil (Info.plist CFBundleDisplayName): \(error)")
    }
}()

import Foundation

/// Disk (toplantı dosyaları, klasörler, ses dosyaları) hataları.
public enum StorageError: Error, Equatable {
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case deleteFailed(path: String, reason: String)
    case directoryUnavailable(path: String, reason: String)
    /// iCloud'a giriş yapılmamış ya da iCloud Drive kapalı (ya da uygulamanın iCloud yetkisi yok).
    case iCloudUnavailable
    /// Taşıma hedefinde aynı adlı klasör var (üzerine yazılmaz).
    case alreadyExists(path: String)
    case moveFailed(path: String, reason: String)
    /// Uygulamanın Info.plist'inde veri klasörü adı yok (derleme yapılandırması hatası; bkz. `dataFolderInfoKey`).
    case dataFolderNotConfigured(key: String, bundle: String)
    /// Hesap başına veride henüz hesap yüklenmedi (giriş yapılmadı); eski ortak klasöre düşülmez.
    case accountNotSelected
    /// Hesap anahtarı beklenen biçimde değil (bkz. `isValidAccountDataKey`).
    case invalidAccountKey(key: String)
    /// Bu süreçte başka bir hesabın verisi yüklü; yeni hesabınki için uygulama yeniden başlamalı.
    case accountSwitchRequiresRelaunch(active: String, requested: String)
    /// Eski veri hesaba taşınamadı: hedefte aynı adlı öğe var (hiçbir şey taşınmadı, üzerine yazılmadı).
    case legacyDataConflict(source: String, destination: String)
    /// Eski veri hesaba taşınırken bir öğe taşınamadı; o ve sonrakiler yerinde kaldı (`movedSoFar` öğe taşındı).
    case legacyDataMoveFailed(source: String, destination: String, reason: String, movedSoFar: Int)
}

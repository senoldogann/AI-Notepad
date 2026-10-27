import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kayıt sekmesi: yüz yüze toplantıyı mikrofonla kaydetme (aşama 2'de canlı metin ve çeviriyle çalışır).
struct RecordTab: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "waveform")
                    .appFont(size: 34, weight: .regular)
                    .foregroundStyle(Theme.muted)
                Text("Yüz yüze toplantını kaydet")
                    .appFont(size: 24, weight: .regular)
                    .tracking(-0.3)
                Text("Telefon mikrofonuyla kaydeder, canlı metni ve Türkçe çevirisini gösterir, toplantı bitince notu yazar. Telefondaki Teams/Zoom görüşmeleri kaydedilemez (iOS izin vermez); onlar için Mac'i kullan.")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Text("Kayıt bir sonraki sürümde açılıyor.")
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.muted)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Theme.background)
            .navigationTitle("Kayıt")
        }
    }
}

/// Henüz dolmamış sekme (aşama 3).
struct ComingSoonTab: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        NavigationStack {
            VStack {
                EmptyStateCard(symbol: symbol, title: title, message: "Bu bölüm bir sonraki sürümde geliyor.")
                    .padding(16)
                Spacer()
            }
            .background(Theme.background)
            .navigationTitle(title)
        }
    }
}

/// Ayarlar: sürüm ve arşivin yeri (eşitleme ve anahtarlar aşama 4'te).
struct PhoneSettingsTab: View {
    let store: PhoneStore

    var body: some View {
        NavigationStack {
            List {
                Section("Uygulama") {
                    LabeledContent("Sürüm", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("Toplantılar", value: "\(store.meetings.count)")
                }
                Section("Eşitleme") {
                    Text("Toplantılar şimdilik bu iPhone'da saklanır. iCloud ile Mac'le eşitleme bir sonraki sürümlerde açılıyor.")
                        .foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle("Ayarlar")
        }
    }
}

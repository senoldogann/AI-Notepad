import AINotepadCore
import AINotepadUI
import SwiftUI

// iPhone'un ortak tasarım parçaları: Mac'teki ElevenLabs dili (sakin zemin, Inter, film gradyanlı kapaklar, soluk
// konuşmacı renkleri) telefona uygun ölçülerle.

/// Bölüm başlığı: büyük harfli küçük etiket ve isteğe bağlı sağda eylem ("Tümünü gör ›").
struct PhoneSectionHeader: View {
    let title: LocalizedStringKey
    let actionTitle: LocalizedStringKey?
    let action: (@MainActor () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .appFont(size: 12, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right").appFont(size: 10, weight: .semibold)
                    }
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// "Bir bakışta" kutusu: büyük sayı ve altında etiket.
struct PhoneStatTile: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .appFont(size: 24, weight: .regular)
                .tracking(-0.4)
                .monospacedDigit()
            Text(label)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Konuşmacı rozeti: kişinin soluk renginde daire içinde numarası ("Sen" için kişi simgesi).
struct SpeakerBadge: View {
    let speaker: Speaker
    let person: Int?
    let size: CGFloat

    var body: some View {
        let color: Color = person.map { personColor(person: $0) } ?? (speaker == .me ? DesignTokens.meSpeakerColor : Theme.muted)
        ZStack {
            Circle().fill(color.opacity(0.16))
            if let person {
                Text(verbatim: "\(person)")
                    .appFont(size: size * 0.42, weight: .semibold)
                    .foregroundStyle(color)
            } else {
                Image(systemName: speaker == .me ? "person.fill" : "person.2.fill")
                    .appFont(size: size * 0.38, weight: .semibold)
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Hap sekmeler (Mac'teki Özet/Transkript gibi): soluk zemin üstünde seçili sekme beyaz hap.
struct PillTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: LocalizedStringKey)]
    @Namespace private var namespace: Namespace.ID
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { (item: (offset: Int, element: (value: Value, title: LocalizedStringKey))) in
                let isSelected: Bool = selection == item.element.value
                Button {
                    withAnimation(.smooth(duration: 0.25)) { selection = item.element.value }
                } label: {
                    Text(item.element.title)
                        .appFont(size: 14, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if isSelected {
                                Capsule()
                                    // Koyu zeminde seçili hap zeminden açık olmalı (kart rengi koyuda daha koyu).
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Theme.card)
                                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Theme.soft, in: Capsule())
    }
}

/// Kapak (film gradyanı) üstündeki cam çip: beyaz yazı, yarı saydam zemin.
struct GlassChip: View {
    let text: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).appFont(size: 11, weight: .semibold)
            }
            Text(text)
        }
        .appFont(size: 12, weight: .medium)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.24)))
    }
}

/// Konuşmacı zaman çizgisi: toplantı boyunca kim ne zaman konuştu (kapakta ince renkli şerit).
struct SpeakerStrip: View {
    let spans: [SpeakerSpan]
    let totalSec: Double

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                ForEach(Array(spans.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerSpan)) in
                    let span: SpeakerSpan = item.element
                    let color: Color = span.key.person.map { personColor(person: $0) } ?? DesignTokens.meSpeakerColor
                    Capsule()
                        .fill(color.mix(with: .white, by: 0.25))
                        .frame(width: max(2, proxy.size.width * (span.endSec - span.startSec) / max(totalSec, 1)))
                        .offset(x: proxy.size.width * span.startSec / max(totalSec, 1))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Bitmemiş toplantının durumu (kartta); bitmişse boş. Saf fonksiyondur.
func meetingStatusText(status: MeetingStatus) -> String? {
    switch status {
    case .recording: String(localized: "Kayıtta")
    case .processing: String(localized: "Hazırlanıyor")
    case .failed: String(localized: "Hata")
    case .interrupted: String(localized: "Yarıda kaldı")
    case .done: nil
    }
}

/// Toplantı satırı: toplantıya özgü küçük renk kimliği, başlık, saat · süre · dil; sağda sana düşen açık görev sayısı ya
/// da durum.
struct PhoneMeetingRow: View {
    let record: MeetingRecord

    var body: some View {
        let myTasks: Int = (record.note?.tasks ?? []).filter { $0.isMine && !isTaskDone(record: record, task: $0) }.count
        HStack(spacing: 12) {
            CoverBackground(seed: record.id)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.note?.title ?? record.title)
                    .appFont(size: 16, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if let status = meetingStatusText(status: record.status) {
                Text(status)
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(record.status == .failed ? Color.red : Theme.muted)
            } else if myTasks > 0 {
                Text(String(localized: "\(myTasks) görev"))
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.ink)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let time: String = record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))
        let minutes: [String] = meetingDurationMinutes(record: record).map { [String(localized: "\($0) dk")] } ?? []
        let language: [String] = record.language.map { [$0.flag] } ?? []
        return ([time] + minutes + language).joined(separator: " · ")
    }
}

/// Hata satırları (turuncu, okunur boyutta).
struct PhoneErrorList: View {
    let messages: [String]

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages, id: \.self) { (message: String) in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

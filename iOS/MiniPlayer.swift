import AINotepadCore
import AINotepadUI
import SwiftUI

/// Sekme çubuğunun üstündeki mini çalar (Apple Müzik gibi): toplantı adı ve o anki konuşmacı, ilerleme, 15 sn geri,
/// oynat/duraklat, kapat. Ada dokununca toplantı açılır.
struct MiniPlayer: View {
    let player: MeetingAudioPlayer
    let store: PhoneStore
    let router: PhoneRouter
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement: TabViewBottomAccessoryPlacement?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let record: MeetingRecord? = player.meetingID.flatMap { (id: String) -> MeetingRecord? in store.meetings.first { $0.id == id } }
        HStack(spacing: 12) {
            Button {
                if let id = player.meetingID {
                    router.open(meetingID: id)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .foregroundStyle(appearance.accent.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.map { $0.note?.title ?? $0.title } ?? "")
                            .appFont(size: 13, weight: .semibold)
                            .lineLimit(1)
                        if placement != .inline {
                            PlayerTime(player: player)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if placement != .inline {
                Button {
                    player.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15").appFont(size: 17, weight: .medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("15 saniye geri")
            }
            Button {
                player.togglePause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .appFont(size: 19, weight: .medium)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Duraklat" : "Oynat")
            Button {
                player.stop()
            } label: {
                Image(systemName: "xmark").appFont(size: 14, weight: .semibold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Çalmayı kapat")
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16)
    }
}

/// Mini çalardaki süre: "01:24 / 09:58". Yalnızca bu görünüm konumu okur (saniyede ~30 güncelleme).
private struct PlayerTime: View {
    let player: MeetingAudioPlayer

    var body: some View {
        Text(verbatim: "\(timestamp(seconds: player.currentTime)) / \(timestamp(seconds: player.duration))")
            .appFont(size: 11, weight: .regular)
            .monospacedDigit()
            .foregroundStyle(Theme.muted)
    }
}

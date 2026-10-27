import AINotepadCore
import SwiftUI

/// Oynatıcının konumunu izleyen görünmez görünüm: konum her güncellendiğinde yalnızca bu küçük görünüm yeniden
/// hesaplanır; çalan paragraf değişince `onChange` çağrılır.
public struct PlaybackFollower: View {
    let player: MeetingAudioPlayer
    let meetingID: String
    let paragraphs: [TranscriptParagraph]
    let onChange: @MainActor (String?) -> Void

    public init(player: MeetingAudioPlayer, meetingID: String, paragraphs: [TranscriptParagraph], onChange: @escaping @MainActor (String?) -> Void) {
        self.player = player
        self.meetingID = meetingID
        self.paragraphs = paragraphs
        self.onChange = onChange
    }

    public var body: some View {
        let active: String? = player.meetingID == meetingID ? activeParagraphID(paragraphs: paragraphs, timeSec: player.currentTime) : nil
        Color.clear
            .onChange(of: active, initial: true) { (_: String?, id: String?) in onChange(id) }
    }
}

/// Çalan paragrafın kelime kelime vurgusu: yalnızca bu görünüm konumu okur (saniyede ~30 güncelleme).
public struct KaraokeParagraph: View {
    let words: [StoredWord]
    let player: MeetingAudioPlayer
    let accent: Color

    public init(words: [StoredWord], player: MeetingAudioPlayer, accent: Color) {
        self.words = words
        self.player = player
        self.accent = accent
    }

    public var body: some View {
        Text(karaokeText(words: words, activeIndex: activeWordIndex(words: words, timeSec: player.currentTime), accent: accent))
    }
}

import AINotepadCore
import AINotepadUI
import SwiftUI

/// Toplantılar: film gradyanlı kartlar (en yeni önce) ve arama; dokununca toplantının notu ve transkripti.
struct MeetingsTab: View {
    let store: PhoneStore
    @Bindable var router: PhoneRouter
    let player: MeetingAudioPlayer
    /// Kayıt sürüyorsa çalma kapalıdır (mikrofon ve hoparlör aynı ses oturumunu paylaşamaz).
    let isRecording: Bool
    @State private var query: String = ""

    var body: some View {
        NavigationStack(path: $router.meetingsPath) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(store.problems, id: \.self) { (problem: String) in
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.meetings.isEmpty {
                        EmptyStateCard(
                            symbol: "list.bullet.rectangle", title: "Henüz toplantı yok",
                            message: "Kayıt sekmesinden yüz yüze bir toplantıyı kaydet; Mac'teki toplantıların da iCloud eşitlemesiyle burada görünecek."
                        )
                    }
                    ForEach(filterMeetings(records: store.meetings, query: query), id: \.id) { (record: MeetingRecord) in
                        NavigationLink(value: record.id) {
                            MeetingCard(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle("Toplantılar")
            .searchable(text: $query, prompt: "Toplantılarda ara")
            .navigationDestination(for: String.self) { (id: String) in
                if let record = store.meetings.first(where: { $0.id == id }) {
                    MeetingReadView(record: record, store: store, player: player, isRecording: isRecording)
                }
            }
            .refreshable { store.reload() }
        }
    }
}

/// Toplantı kartı: kapak gradyanı üstünde başlık, tarih, süre ve durum.
private struct MeetingCard: View {
    let record: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text(record.note?.title ?? record.title)
                .appFont(size: 17, weight: .semibold)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(cardSubtitle)
                .appFont(size: 12, weight: .regular)
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .bottomLeading)
        .background { CoverBackground(seed: record.id) }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cardSubtitle: String {
        let date: String = record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))
        let minutes: [String] = meetingDurationMinutes(record: record).map { [String(localized: "\($0) dk")] } ?? []
        return ([date] + minutes + statusText(status: record.status)).joined(separator: " · ")
    }
}

/// Bitmemiş toplantının durumu (kartta); bitmişse boş. Saf fonksiyondur.
private func statusText(status: MeetingStatus) -> [String] {
    switch status {
    case .recording: [String(localized: "Kayıtta")]
    case .processing: [String(localized: "Hazırlanıyor")]
    case .failed: [String(localized: "Hata")]
    case .interrupted: [String(localized: "Yarıda kaldı")]
    case .done: []
    }
}

/// Toplantı sayfasının sekmesi.
private enum MeetingPane: Hashable {
    case summary
    case transcript
}

/// Toplantı sayfası: kapak (tarih, başlık, süre, "Dinle"), Özet (görevler, özet, kararlar, konu akışı) ve Transkript
/// (konuşmacılı paragraflar; çalarken o anki kelime vurgulanır, dokununca oradan çalar).
struct MeetingReadView: View {
    let record: MeetingRecord
    let store: PhoneStore
    let player: MeetingAudioPlayer
    let isRecording: Bool
    @State private var pane: MeetingPane = .summary
    @State private var errorMessage: String?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(.orange)
                    }
                    if let failure = record.failureMessage ?? record.notice {
                        Text(failure)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    Picker("Görünüm", selection: $pane) {
                        Text("Özet").tag(MeetingPane.summary)
                        Text("Transkript").tag(MeetingPane.transcript)
                    }
                    .pickerStyle(.segmented)
                    switch pane {
                    case .summary:
                        MeetingSummary(record: record, store: store, canPlay: canPlay) { (startSec: Double) -> Void in
                            play(from: startSec)
                        }
                    case .transcript:
                        TranscriptList(record: record, player: player, canPlay: canPlay, proxy: proxy) { (startSec: Double) -> Void in
                            play(from: startSec)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .task {
            // `--cal <sn>` (yalnız Debug, görsel kontrol): transkripti açıp o saniyeden çalar.
            if let index = CommandLine.arguments.firstIndex(of: "--cal"), CommandLine.arguments.indices.contains(index + 1),
               let startSec = Double(CommandLine.arguments[index + 1]), player.meetingID == nil {
                pane = .transcript
                play(from: startSec)
            }
        }
        #endif
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(interfaceLocale())).uppercased(with: interfaceLocale()))
                .appFont(size: 11, weight: .medium)
                .tracking(0.6)
                .opacity(0.85)
            Text(record.note?.title ?? record.title)
                .appFont(size: 26, weight: .regular)
                .tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let minutes = meetingDurationMinutes(record: record) {
                    HeroChip(text: String(localized: "\(minutes) dk"))
                }
                if let language = record.language {
                    HeroChip(text: languageName(language: language))
                }
                Spacer(minLength: 0)
                if canPlay {
                    Button {
                        if player.meetingID == record.id {
                            player.togglePause()
                        } else {
                            play(from: 0)
                        }
                    } label: {
                        Label(player.meetingID == record.id && player.isPlaying ? "Duraklat" : "Dinle",
                              systemImage: player.meetingID == record.id && player.isPlaying ? "pause.fill" : "play.fill")
                            .appFont(size: 14, weight: .semibold)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .bottomLeading)
        .background { LivingCoverBackground(seed: record.id) }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Ses varsa ve kayıt sürmüyorsa çalınabilir.
    private var canPlay: Bool {
        !isRecording && !record.audioDeleted && (record.status == .done || record.status == .failed || record.status == .interrupted)
    }

    private func play(from startSec: Double) {
        guard canPlay else {
            return
        }
        do {
            let urls: [URL] = try store.audioURLs(record: record)
            guard !urls.isEmpty else {
                errorMessage = String(localized: "Bu toplantının ses kaydı yok.")
                return
            }
            errorMessage = nil
            player.play(meetingID: record.id, urls: urls, startSec: startSec)
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

/// Kapak üstündeki küçük cam etiket.
private struct HeroChip: View {
    let text: String

    var body: some View {
        Text(text)
            .appFont(size: 12, weight: .medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
    }
}

/// Özet: senin görevlerin (işaretlenebilir), özet, kararlar, konu akışı (dokununca oradan çalar), diğer görevler.
private struct MeetingSummary: View {
    let record: MeetingRecord
    let store: PhoneStore
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        if let note = record.note {
            VStack(alignment: .leading, spacing: 22) {
                let mine: [NoteTask] = note.tasks.filter(\.isMine)
                if !mine.isEmpty {
                    section(title: "SENİN GÖREVLERİN") {
                        ForEach(mine, id: \.trackingKey) { (task: NoteTask) in
                            PhoneTaskRow(record: record, task: task, showsMeeting: false) {
                                store.toggleTask(meetingID: record.id, task: task)
                            }
                        }
                    }
                }
                Text(note.summary)
                    .appFont(size: 17, weight: .regular)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                if !note.decisions.isEmpty {
                    section(title: "KARARLAR") {
                        ForEach(Array(note.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "•").foregroundStyle(Theme.muted)
                                Text(item.element).appFont(size: 15, weight: .regular)
                            }
                        }
                    }
                }
                if let outline = note.outline, !outline.isEmpty {
                    section(title: "KONU AKIŞI") {
                        ForEach(Array(outline.enumerated()), id: \.offset) { (item: (offset: Int, element: OutlineItem)) in
                            Button {
                                onPlay(item.element.startSec)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(timestamp(seconds: item.element.startSec))
                                        .appFont(size: 12, weight: .medium)
                                        .monospacedDigit()
                                        .foregroundStyle(canPlay ? appearance.accent.color : Theme.muted)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.element.title).appFont(size: 15, weight: .medium)
                                        Text(item.element.summary)
                                            .appFont(size: 13, weight: .regular)
                                            .foregroundStyle(Theme.muted)
                                    }
                                    .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canPlay)
                        }
                    }
                }
                let others: [NoteTask] = note.tasks.filter { !$0.isMine }
                if !others.isEmpty {
                    section(title: "DİĞER GÖREVLER") {
                        ForEach(others, id: \.trackingKey) { (task: NoteTask) in
                            PhoneTaskRow(record: record, task: task, showsMeeting: false) {
                                store.toggleTask(meetingID: record.id, task: task)
                            }
                        }
                    }
                }
            }
        } else {
            EmptyStateCard(symbol: "doc.text", title: "Bu toplantının notu yok", message: nil)
        }
    }

    private func section(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
            content()
        }
    }
}

/// Transkript: konuşmacılı paragraflar (≤30 sn). Çalan paragraf hafif dolgulu ve kelime kelime vurgulu; görünür alanın
/// üst üçte birine kayar. Paragrafa dokununca oradan çalar.
private struct TranscriptList: View {
    let record: MeetingRecord
    let player: MeetingAudioPlayer
    let canPlay: Bool
    let proxy: ScrollViewProxy
    let onPlay: @MainActor (Double) -> Void
    /// Çalan paragraf: yalnızca paragraf değişince yazılır (tüm liste saniyede onlarca kez yeniden çizilmesin).
    @State private var activeID: String?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: record)
        LazyVStack(alignment: .leading, spacing: 4) {
            if paragraphs.isEmpty {
                EmptyStateCard(symbol: "text.alignleft", title: "Transkript yok", message: nil)
            }
            ForEach(Array(paragraphs.enumerated()), id: \.element.id) { (item: (offset: Int, element: TranscriptParagraph)) in
                let paragraph: TranscriptParagraph = item.element
                let continues: Bool = item.offset > 0
                    && paragraphs[item.offset - 1].speaker == paragraph.speaker && paragraphs[item.offset - 1].person == paragraph.person
                let isActive: Bool = activeID == paragraph.id
                Button {
                    onPlay(paragraph.startSec)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if !continues {
                                Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames))
                                    .appFont(size: 12, weight: .semibold)
                                    .foregroundStyle(paragraph.person.map { personColor(person: $0) } ?? Theme.ink)
                            }
                            Text(timestamp(seconds: paragraph.startSec))
                                .appFont(size: 11, weight: .regular)
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                        }
                        if isActive {
                            KaraokeParagraph(words: paragraph.words, player: player, accent: appearance.accent.color)
                                .appFont(size: 16, weight: .regular)
                                .lineSpacing(3)
                        } else {
                            Text(paragraph.text)
                                .appFont(size: 16, weight: .regular)
                                .lineSpacing(3)
                                .foregroundStyle(Theme.ink)
                        }
                        if let turkish = paragraph.turkish {
                            Text(turkish)
                                .appFont(size: 14, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isActive ? Theme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, continues ? 0 : 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .id(paragraph.id)
            }
        }
        .padding(.horizontal, -10)
        .background {
            PlaybackFollower(player: player, meetingID: record.id, paragraphs: paragraphs) { (id: String?) -> Void in
                activeID = id
                if let id, player.isPlaying {
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                }
            }
        }
    }
}

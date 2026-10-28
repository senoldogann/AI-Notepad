import AINotepadCore
import AINotepadUI
import SwiftUI

/// Toplantılar: tarihe göre gruplanmış film gradyanlı kartlar ve arama; uzun basınca silme. Dokununca toplantı sayfası.
struct MeetingsTab: View {
    let store: PhoneStore
    @Bindable var router: PhoneRouter
    let player: MeetingAudioPlayer
    /// Kayıt sürüyorsa çalma kapalıdır (mikrofon ve hoparlör aynı ses oturumunu paylaşamaz).
    let isRecording: Bool
    @State private var query: String = ""
    @State private var pendingDelete: MeetingRecord?
    @State private var deleteError: String?
    /// Kart, açılan toplantıya büyüyerek geçer (kapanınca kartına döner).
    @Namespace private var cardTransition: Namespace.ID

    var body: some View {
        let sections: [MeetingSection] = meetingSections(
            records: filterMeetings(records: store.meetings, query: query), now: Date(), calendar: .current, locale: interfaceLocale()
        )
        NavigationStack(path: $router.meetingsPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    PhoneErrorList(messages: store.problems + [deleteError].compactMap { $0 })
                    if store.downloadingCount > 0 {
                        Label("\(store.downloadingCount) toplantı iCloud'dan iniyor…", systemImage: "icloud.and.arrow.down")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    if store.meetings.isEmpty {
                        EmptyStateHero(
                            symbol: "waveform", title: "Henüz toplantı yok",
                            message: "Kayıt sekmesinden yüz yüze bir toplantıyı kaydet; Mac'teki toplantıların da iCloud eşitlemesiyle burada görünür.",
                            palette: .sunset,
                            steps: [
                                EmptyStateStep(symbol: "mic.fill", title: "Kayıt"),
                                EmptyStateStep(symbol: "sparkles", title: "Not yazılır"),
                                EmptyStateStep(symbol: "icloud", title: "Mac'le eşitlenir"),
                            ]
                        ) {
                            Button("Kaydı başlat", systemImage: "mic.fill") { router.tab = .record }
                                .buttonStyle(.pillPrimary)
                        }
                    } else if sections.isEmpty {
                        EmptyStateCard(symbol: "magnifyingglass", title: "Eşleşen toplantı yok", message: nil)
                    }
                    ForEach(sections) { (section: MeetingSection) in
                        Text(section.title)
                            .appFont(size: 13, weight: .semibold)
                            .tracking(DesignTokens.labelTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 10)
                        ForEach(section.meetings, id: \.id) { (record: MeetingRecord) in
                            NavigationLink(value: record.id) {
                                PhoneMeetingCard(record: record, height: 132)
                                    .matchedTransitionSource(id: record.id, in: cardTransition)
                            }
                            .buttonStyle(PressableCardStyle())
                            .contextMenu {
                                Button("Sil", systemImage: "trash", role: .destructive) { pendingDelete = record }
                                    .disabled(record.status == .recording || record.status == .processing)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .navigationTitle("Toplantılar")
            .searchable(text: $query, prompt: "Toplantılarda ara")
            .navigationDestination(for: String.self) { (id: String) in
                if let record = store.meetings.first(where: { $0.id == id }) {
                    MeetingReadView(record: record, store: store, player: player, isRecording: isRecording) {
                        pendingDelete = record
                    }
                    .navigationTransition(.zoom(sourceID: id, in: cardTransition))
                }
            }
            .refreshable { store.reload() }
            .confirmationDialog(
                "Toplantı silinsin mi?", isPresented: Binding<Bool>(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { (record: MeetingRecord) in
                Button("Sil", role: .destructive) { delete(record: record) }
            } message: { (_: MeetingRecord) in
                Text("Not, transkript ve ses kalıcı olarak silinir; geri alınamaz.")
            }
        }
    }

    private func delete(record: MeetingRecord) {
        if player.meetingID == record.id {
            player.stop()
        }
        do {
            try store.deleteMeeting(id: record.id)
            deleteError = nil
            router.meetingsPath.removeAll { $0 == record.id }
        } catch {
            deleteError = String(localized: "Toplantı silinemedi: \(userFacingMessage(error: error))")
        }
    }
}

/// Toplantı sayfasının sekmesi.
private enum MeetingPane: Hashable {
    case summary
    case transcript
}

/// Toplantı sayfası: kapak (tarih, başlık, çipler, konuşmacı şeridi, Dinle, paylaş), Özet (görevler, özet, bir bakışta,
/// konuşma payları, kararlar, konu akışı, diğer görevler, sözlük) ve Transkript (konuşmacılı paragraflar; çalarken o
/// anki kelime vurgulanır, dokununca oradan çalar). Sağ üstte paylaş ve sil.
struct MeetingReadView: View {
    let record: MeetingRecord
    let store: PhoneStore
    let player: MeetingAudioPlayer
    let isRecording: Bool
    let onDelete: @MainActor () -> Void
    @State private var pane: MeetingPane = .summary
    @State private var errorMessage: String?

    var body: some View {
        let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: record)
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero(paragraphs: paragraphs)
                    // Çalma hatası (dosya açılamadı, ses oturumu) da burada görünür.
                    let messages: [String] = [errorMessage, player.errorMessage].compactMap { $0 }
                    if !messages.isEmpty {
                        PhoneErrorList(messages: messages)
                    }
                    if let failure = record.failureMessage ?? record.notice {
                        Label(failure, systemImage: "info.circle")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    PillTabs(selection: $pane, options: [(MeetingPane.summary, "Özet"), (MeetingPane.transcript, "Transkript")])
                    switch pane {
                    case .summary:
                        MeetingSummary(record: record, paragraphs: paragraphs, store: store, canPlay: canPlay) { (startSec: Double) -> Void in
                            play(from: startSec)
                        }
                        .transition(.opacity)
                    case .transcript:
                        TranscriptList(record: record, paragraphs: paragraphs, player: player, canPlay: canPlay, proxy: proxy) { (startSec: Double) -> Void in
                            play(from: startSec)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let note = record.note {
                        ShareLink(item: shareText(record: record, note: note, language: nil)) {
                            Label("Notu paylaş", systemImage: "square.and.arrow.up")
                        }
                        ShareLink(item: meetingMarkdown(record: record)) {
                            Label("Markdown olarak paylaş", systemImage: "doc.text")
                        }
                    }
                    if !(record.finalSegments.isEmpty && record.liveSegments.isEmpty) {
                        ShareLink(item: transcriptText(record: record)) {
                            Label("Transkripti paylaş", systemImage: "text.alignleft")
                        }
                    }
                    Button(store.regeneratingIDs.contains(record.id) ? "Not yazılıyor…" : "Notu yenile", systemImage: "arrow.clockwise") {
                        Task { await store.regenerateNote(meetingID: record.id) }
                    }
                    .disabled(record.status == .recording || record.status == .processing || store.regeneratingIDs.contains(record.id))
                    if let versions = record.noteHistory, !versions.isEmpty {
                        Menu("Önceki sürümler", systemImage: "clock.arrow.circlepath") {
                            Section("Değişiklikten önceki not") {
                                ForEach(Array(versions.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteVersion)) in
                                    Button(noteVersionTitle(version: item.element, locale: interfaceLocale())) {
                                        restoreVersion(index: item.offset)
                                    }
                                }
                            }
                        }
                        .disabled(record.status == .recording || record.status == .processing || store.regeneratingIDs.contains(record.id))
                    }
                    Button("Sil", systemImage: "trash", role: .destructive, action: onDelete)
                        .disabled(record.status == .recording || record.status == .processing)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Diğer")
            }
        }
        #if DEBUG
        .task {
            // `--cal <sn>` (yalnız Debug, görsel kontrol): transkripti açıp o saniyeden çalar.
            if let index = CommandLine.arguments.firstIndex(of: "--cal"), CommandLine.arguments.indices.contains(index + 1),
               let startSec = Double(CommandLine.arguments[index + 1]), player.meetingID == nil {
                play(from: startSec)
            }
        }
        #endif
    }

    /// Notun önceki sürümünü geri yükler; olmazsa neden sayfada görünür.
    private func restoreVersion(index: Int) {
        do {
            try store.restoreNoteVersion(meetingID: record.id, index: index)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Not sürümü geri yüklenemedi: \(userFacingMessage(error: error))")
        }
    }

    private func hero(paragraphs: [TranscriptParagraph]) -> some View {
        let shares: [SpeakerShare] = speakerShares(paragraphs: paragraphs)
        let totalSec: Double = paragraphs.map(\.endSec).max() ?? 0
        let isPlayingThis: Bool = player.meetingID == record.id && player.isPlaying
        return VStack(alignment: .leading, spacing: 12) {
            Text(interfaceUppercased(text: record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(interfaceLocale()))))
                .appFont(size: 11, weight: .semibold)
                .tracking(0.6)
                .opacity(0.88)
            Text(record.note?.title ?? record.title)
                .appFont(size: 27, weight: .regular)
                .tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 1)
            HStack(spacing: 6) {
                if let minutes = meetingDurationMinutes(record: record) {
                    GlassChip(text: String(localized: "\(minutes) dk"), systemImage: "clock")
                }
                if let language = record.language {
                    GlassChip(text: languageName(language: language), systemImage: nil)
                }
                if !shares.isEmpty {
                    GlassChip(text: String(localized: "\(shares.count) konuşmacı"), systemImage: "person.2")
                }
            }
            if totalSec > 0, !shares.isEmpty {
                SpeakerStrip(spans: speakerSpans(paragraphs: paragraphs), totalSec: totalSec)
                    .padding(.top, 4)
            }
            HStack(spacing: 10) {
                if canPlay {
                    Button {
                        if player.meetingID == record.id {
                            player.togglePause()
                        } else {
                            play(from: 0)
                        }
                    } label: {
                        Label(isPlayingThis ? "Duraklat" : "Dinle", systemImage: isPlayingThis ? "pause.fill" : "play.fill")
                            .appFont(size: 15, weight: .semibold)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.white, in: Capsule())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PressableCardStyle())
                }
                Spacer()
                if let note = record.note {
                    ShareLink(item: shareText(record: record, note: note, language: nil)) {
                        Image(systemName: "square.and.arrow.up")
                            .appFont(size: 15, weight: .semibold)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.18), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.28)))
                    }
                    .accessibilityLabel("Notu paylaş")
                }
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .bottomLeading)
        .background { CoverBackground(seed: record.id) }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, .dark)
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
            // Mac'te kaydedilen toplantının sesi iCloud'dan henüz inmemiş olabilir: indirme başlatılır.
            if try startDownloadingCloudAudio(directory: try store.sessionDirectory(id: record.id)) {
                errorMessage = String(localized: "Ses iCloud'dan iniyor; birazdan yeniden dene.")
                return
            }
            let urls: [URL] = try store.audioURLs(record: record)
            guard !urls.isEmpty else {
                errorMessage = String(localized: "Bu toplantının ses kaydı yok.")
                return
            }
            errorMessage = nil
            withAnimation(.smooth(duration: 0.25)) { pane = .transcript }
            player.play(meetingID: record.id, urls: urls, startSec: startSec)
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

/// Özet: senin görevlerin (işaretlenebilir), özet, bir bakışta, kim ne kadar konuştu, kararlar, konu akışı (dokununca
/// oradan çalar), diğer görevler, sözlük.
private struct MeetingSummary: View {
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    let store: PhoneStore
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        if let note = record.note {
            let mine: [NoteTask] = note.tasks.filter(\.isMine)
            let others: [NoteTask] = note.tasks.filter { !$0.isMine }
            let shares: [SpeakerShare] = speakerShares(paragraphs: paragraphs)
            VStack(alignment: .leading, spacing: 26) {
                if mine.isEmpty {
                    Label("Bu toplantıda sana düşen görev yok", systemImage: "checkmark.circle")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    section(title: "Senin görevlerin") {
                        ForEach(mine, id: \.trackingKey) { (task: NoteTask) in
                            PhoneTaskRow(record: record, task: task, showsMeeting: false) {
                                withAnimation(.smooth(duration: 0.25)) { store.toggleTask(meetingID: record.id, task: task) }
                            }
                        }
                    }
                }
                if let myNotes = record.myNotes {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("SENİN NOTLARIN", systemImage: "square.and.pencil")
                            .appFont(size: 11, weight: .semibold)
                            .tracking(DesignTokens.labelTracking)
                            .foregroundStyle(appearance.accent.color)
                        Text(myNotes)
                            .appFont(size: 15, weight: .regular)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(appearance.accent.color.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .leading) {
                        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                            .fill(appearance.accent.color.opacity(0.7))
                            .frame(width: 3)
                    }
                }
                Text(note.summary)
                    .font(appearance.readingFont(size: 18, weight: .regular))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    PhoneStatTile(value: meetingDurationMinutes(record: record).map { String(localized: "\($0) dk") } ?? "–", label: "süre")
                    PhoneStatTile(value: "\(shares.count)", label: "konuşmacı")
                    PhoneStatTile(value: "\(note.decisions.count)", label: "karar")
                    PhoneStatTile(value: "\(mine.count)", label: "senin görevin")
                }
                if shares.count > 1 {
                    section(title: "Kim ne kadar konuştu") {
                        ForEach(Array(shares.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerShare)) in
                            ShareRow(share: item.element, speakerNames: record.speakerNames)
                        }
                    }
                }
                if !note.decisions.isEmpty {
                    section(title: "Kararlar") {
                        ForEach(Array(note.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(verbatim: "\(item.offset + 1)")
                                    .appFont(size: 13, weight: .semibold)
                                    .monospacedDigit()
                                    .foregroundStyle(appearance.accent.color)
                                    .frame(width: 18, alignment: .trailing)
                                Text(item.element)
                                    .appFont(size: 16, weight: .regular)
                                    .lineSpacing(3)
                            }
                        }
                    }
                }
                if let outline = note.outline, !outline.isEmpty {
                    section(title: "Konu akışı") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(outline.enumerated()), id: \.offset) { (item: (offset: Int, element: OutlineItem)) in
                                OutlineRow(item: item.element, isLast: item.offset == outline.count - 1, canPlay: canPlay) {
                                    onPlay(item.element.startSec)
                                }
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    section(title: "Diğer görevler") {
                        ForEach(others, id: \.trackingKey) { (task: NoteTask) in
                            PhoneTaskRow(record: record, task: task, showsMeeting: false) {
                                withAnimation(.smooth(duration: 0.25)) { store.toggleTask(meetingID: record.id, task: task) }
                            }
                        }
                    }
                }
                if !note.glossary.isEmpty {
                    section(title: "Sözlük") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(note.glossary.enumerated()), id: \.offset) { (item: (offset: Int, element: GlossaryEntry)) in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.element.term).appFont(size: 15, weight: .semibold)
                                    Text(item.element.meaning)
                                        .appFont(size: 14, weight: .regular)
                                        .foregroundStyle(Theme.muted)
                                }
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
        VStack(alignment: .leading, spacing: 12) {
            PhoneSectionHeader(title: title, actionTitle: nil, action: nil)
            content()
        }
    }
}

/// Konuşma payı satırı: rozet, ad, yüzde ve kişinin renginde ince çubuk.
private struct ShareRow: View {
    let share: SpeakerShare
    let speakerNames: [Int: String]

    var body: some View {
        let color: Color = share.key.person.map { personColor(person: $0) } ?? DesignTokens.meSpeakerColor
        HStack(spacing: 10) {
            SpeakerBadge(speaker: share.key.speaker, person: share.key.person, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(share.key.person.flatMap { speakerNames[$0] } ?? speakerLabel(speaker: share.key.speaker, person: share.key.person))
                        .appFont(size: 14, weight: .medium)
                    Spacer()
                    Text(verbatim: "%\(Int((share.fraction * 100).rounded()))")
                        .appFont(size: 13, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                GeometryReader { (proxy: GeometryProxy) in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.soft)
                        Capsule().fill(color).frame(width: proxy.size.width * share.fraction)
                    }
                }
                .frame(height: 5)
            }
        }
    }
}

/// Konu akışı satırı: solda saat ve ince dikey çizgi (zaman çizelgesi), sağda başlık ve tek cümle; dokununca çalar.
private struct OutlineRow: View {
    let item: OutlineItem
    let isLast: Bool
    let canPlay: Bool
    let onPlay: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").appFont(size: 8, weight: .bold)
                        Text(timestamp(seconds: item.startSec))
                            .appFont(size: 12, weight: .semibold)
                            .monospacedDigit()
                    }
                    .foregroundStyle(canPlay ? appearance.accent.color : Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((canPlay ? appearance.accent.color : Theme.muted).opacity(0.10), in: Capsule())
                    if !isLast {
                        Rectangle().fill(Theme.line).frame(width: 1).frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).appFont(size: 15, weight: .semibold)
                    Text(item.summary)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(2)
                }
                .multilineTextAlignment(.leading)
                .padding(.bottom, isLast ? 0 : 16)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
    }
}

/// Transkript: konuşmacılı paragraflar (≤30 sn), sohbet gibi rozetle. Çalan paragraf hafif dolgulu ve kelime kelime
/// vurgulu; görünür alanın üst üçte birine kayar. Paragrafa dokununca oradan çalar.
private struct TranscriptList: View {
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    let player: MeetingAudioPlayer
    let canPlay: Bool
    let proxy: ScrollViewProxy
    let onPlay: @MainActor (Double) -> Void
    /// Çalan paragraf: yalnızca paragraf değişince yazılır (tüm liste saniyede onlarca kez yeniden çizilmesin).
    @State private var activeID: String?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
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
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if continues {
                                Color.clear
                            } else {
                                SpeakerBadge(speaker: paragraph.speaker, person: paragraph.person, size: 30)
                            }
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if !continues {
                                    Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames))
                                        .appFont(size: 13, weight: .semibold)
                                        .foregroundStyle(paragraph.person.map { personColor(person: $0) } ?? Theme.ink)
                                }
                                Text(timestamp(seconds: paragraph.startSec))
                                    .appFont(size: 11, weight: .regular)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.muted)
                            }
                            Group {
                                if isActive {
                                    KaraokeParagraph(words: paragraph.words, player: player, accent: appearance.accent.color)
                                } else {
                                    Text(paragraph.text).foregroundStyle(Theme.ink)
                                }
                            }
                            .font(appearance.readingFont(size: 16, weight: .regular))
                            .lineSpacing(4)
                            if let turkish = paragraph.turkish {
                                Text(turkish)
                                    .appFont(size: 14, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(isActive ? Theme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, continues ? 0 : 8)
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
                withAnimation(.easeOut(duration: 0.2)) { activeID = id }
                if let id, player.isPlaying {
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                }
            }
        }
    }
}

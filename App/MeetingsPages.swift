import AINotepadCore
import AINotepadUI
import AppKit
import os
import SwiftUI

private let meetingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Meetings")

// MARK: Liste

/// Panelin Toplantılar sayfası: arama ve yeniden eskiye liste.
struct MeetingsListPage: View {
    let model: AppModel
    let onOpen: @MainActor (String) -> Void
    @State private var query: String = ""

    var body: some View {
        let visible: [MeetingRecord] = filterMeetings(records: model.meetings, query: query)
        VStack(spacing: 0) {
            TextField("Toplantılarda ara", text: $query)
                .textFieldStyle(.plain)
                .font(DesignTokens.statusFont)
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
                .padding(DesignTokens.Spacing.m)
            if model.meetings.isEmpty {
                ContentUnavailableView("Henüz toplantı yok", systemImage: "waveform", description: Text("Kaydı başlatınca toplantılar burada görünür."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { (record: MeetingRecord) in
                            Button {
                                onOpen(record.id)
                            } label: {
                                MeetingRow(record: record, isProcessing: model.processingMeetingIDs.contains(record.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.s)
                }
            }
            if !model.meetingLoadFailures.isEmpty {
                Text("\(model.meetingLoadFailures.count) toplantı okunamadı: \(model.meetingLoadFailures.map(\.folder).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(DesignTokens.Spacing.m)
            }
        }
        .onAppear {
            model.reloadMeetings()
            model.applyRetention()
        }
    }
}

/// Liste satırı: başlık, tarih, durum ve varsa senin görev sayın.
private struct MeetingRow: View {
    let record: MeetingRecord
    let isProcessing: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.note?.title ?? record.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.startedAt.formatted(interfaceDate(date: .abbreviated)))
                    if let status = statusText(record: record, isProcessing: isProcessing) {
                        Text("· " + status).foregroundStyle(record.status == .failed ? .red : .secondary)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            let mine: Int = record.note?.tasks.filter(\.isMine).count ?? 0
            if mine > 0 {
                Label("\(mine)", systemImage: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.meColor)
                    .help("Sana düşen görev sayısı")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, DesignTokens.Spacing.s)
        .contentShape(Rectangle())
    }
}

/// Arayüz dilinde tarih + saat biçimi.
private func interfaceDate(date: Date.FormatStyle.DateStyle) -> Date.FormatStyle {
    Date.FormatStyle(date: date, time: .shortened).locale(interfaceLocale())
}

/// Liste ve ayrıntıda gösterilen durum; tamamlanmışsa nil.
private func statusText(record: MeetingRecord, isProcessing: Bool) -> String? {
    if isProcessing {
        return String(localized: "Not hazırlanıyor…")
    }
    switch record.status {
    case .recording: return String(localized: "Kayıtta")
    case .processing: return String(localized: "Not hazırlanıyor…")
    case .done: return nil
    case .failed: return String(localized: "Hata")
    case .interrupted: return String(localized: "Yarıda kaldı")
    }
}

// MARK: Ayrıntı

/// Toplantı sayfasının sekmeleri.
private enum MeetingTab {
    case summary
    case transcript
}

/// Dışa aktarmanın sonucu (sayfada satır içinde gösterilir; açılır pencere yok).
private enum ExportStatus: Equatable {
    case none
    case saved(URL)
    case copied
    case failed(String)
}

/// Seçili toplantının sayfası: önce sana düşen görevler, sonra özet, kararlar, diğer görevler, sözlük,
/// konuşmacı adları ve paragraflı transkript (zaman damgasından çalma).
struct MeetingDetailPage: View {
    let model: AppModel
    let player: MeetingAudioPlayer
    let record: MeetingRecord
    @State private var export: ExportStatus = .none
    @State private var tab: MeetingTab = .summary

    private var isProcessing: Bool {
        model.processingMeetingIDs.contains(record.id)
    }

    /// Kayıtta ya da işlemede: değiştiren eylemler kapalı.
    private var isLocked: Bool {
        model.isLocked(meetingID: record.id)
    }

    var body: some View {
        // Paragraflar burada bir kez hesaplanır: çalma sırasında (saniyede 10 güncelleme) yeniden süzülmez.
        let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: record)
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    header
                    statusLines
                    Picker("Bölüm", selection: $tab) {
                        Text("Özet").tag(MeetingTab.summary)
                        Text("Transkript").tag(MeetingTab.transcript)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch tab {
                    case .summary:
                        if let note = record.note {
                            NoteSections(note: note)
                        } else {
                            Text(isProcessing ? "Not hazırlanıyor…" : "Bu toplantının notu yok.")
                                .foregroundStyle(.secondary)
                        }
                    case .transcript:
                        SpeakerNamesSection(model: model, record: record, isLocked: isLocked)
                        TranscriptSection(
                            record: record, paragraphs: paragraphs, player: player, proxy: proxy,
                            onPlay: { (startSec: Double) -> Void in play(from: startSec) }
                        )
                    }
                }
                .padding(DesignTokens.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if player.meetingID == record.id {
                NowPlayingBar(player: player, paragraphs: paragraphs, speakerNames: record.speakerNames)
            }
        }
        .onAppear {
            // Not varsa önce özet: toplantıdan sonra ilk bakılacak şey; yoksa transkript.
            tab = record.note == nil ? .transcript : .summary
        }
        .onDisappear { player.stop() }
        // Saklama süresi sesi bu sayfa açıkken silebilir.
        .onChange(of: record.audioDeleted) { (_: Bool, deleted: Bool) in
            if deleted {
                player.stop()
            }
        }
    }

    /// İşleniyor, hata ve uyarı satırları.
    @ViewBuilder
    private var statusLines: some View {
        if isProcessing || record.status == .processing {
            HStack(spacing: DesignTokens.Spacing.s) {
                ProgressView().controlSize(.small)
                Text(record.engine == .local
                    ? "Konuşmacılar Mac'te ayrılıyor ve not hazırlanıyor…"
                    : "Kaydın tamamı işleniyor ve not hazırlanıyor…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        if let message = record.failureMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let notice = record.notice {
            Label(notice, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Toplantıyı verilen andan iki kayıt birlikte çalar ve transkripte geçer (kelimeler vurgulansın).
    private func play(from startSec: Double) {
        let urls: [URL] = playableAudio
        guard !urls.isEmpty else {
            return
        }
        tab = .transcript
        player.play(meetingID: record.id, urls: urls, startSec: startSec)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text(record.note?.title ?? record.title)
                .font(.system(size: 20, weight: .semibold))
                .textSelection(.enabled)
            Text(meetingMetaLine(record: record))
                .font(.callout)
                .foregroundStyle(.secondary)
            actions
            exportLine
        }
    }

    /// Dışa aktarma ve yönetim; kilitliyken değiştirenler kapalı.
    private var actions: some View {
        // Düğmeler satıra sığmazsa alt satıra akar (dar panel).
        FlowLayout(spacing: DesignTokens.Spacing.s, lineSpacing: 6) {
                if !playableAudio.isEmpty {
                    Button("Dinle", systemImage: "play.fill") {
                        if player.meetingID == record.id {
                            player.togglePause()
                        } else {
                            play(from: 0)
                        }
                    }
                    .hoverHint("Baştan dinle; çalan kelime renklenir", alignment: .leading, edge: .bottom)
                }
                Button("PDF", systemImage: "doc.richtext") { exportPDF() }
                    .hoverHint("PDF olarak İndirilenler'e kaydet", alignment: .leading, edge: .bottom)
                Button("Markdown", systemImage: "square.and.arrow.down") { exportMarkdown() }
                    .hoverHint("Markdown olarak kaydet", alignment: .leading, edge: .bottom)
                Button("Kopyala", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meetingMarkdown(record: record), forType: .string)
                    export = .copied
                }
                .hoverHint("Markdown olarak kopyala", alignment: .leading, edge: .bottom)
                Button("Notu yenile", systemImage: "sparkles") {
                    model.regenerateNote(meetingID: record.id)
                }
                .disabled(isLocked)
                .hoverHint("Notu adlarla yeniden yaz", alignment: .leading, edge: .bottom)
                Button("Tekrar işle", systemImage: "arrow.clockwise") {
                    model.reprocess(meetingID: record.id)
                }
                .disabled(isLocked || record.audioDeleted)
                .hoverHint("Son geçişi ve notu yeniden yap", alignment: .leading, edge: .bottom)
                Button("Sesi sil", systemImage: "trash", role: .destructive) {
                    player.stop()
                    model.deleteAudio(meetingID: record.id)
                }
                .disabled(isLocked || record.audioDeleted)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var exportLine: some View {
        switch export {
        case .none:
            if record.audioDeleted {
                Text("Ses dosyaları silindi; metin ve not duruyor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .saved(let url):
            HStack(spacing: 6) {
                Label("İndirilenler'e kaydedildi: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Finder'da göster") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        case .copied:
            Label("Markdown panoya kopyalandı", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func exportPDF() {
        export = saveExport(fileExtension: "pdf") { (url: URL) throws -> Void in
            try meetingPDF(record: record).write(to: url, options: .atomic)
        }
    }

    private func exportMarkdown() {
        export = saveExport(fileExtension: "md") { (url: URL) throws -> Void in
            try Data(meetingMarkdown(record: record).utf8).write(to: url, options: .atomic)
        }
    }

    /// Dosyayı İndirilenler'e (aynı ad varsa numaralı) yazar.
    private func saveExport(fileExtension: String, write: (URL) throws -> Void) -> ExportStatus {
        do {
            let downloads: URL = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let url: URL = exportFileURL(directory: downloads, title: record.note?.title ?? record.title, startedAt: record.startedAt, fileExtension: fileExtension)
            do {
                try write(url)
            } catch {
                throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
            }
            return .saved(url)
        } catch {
            meetingsLogger.error("Dışa aktarılamadı, uzantı: \(fileExtension, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            return .failed(userFacingMessage(error: error))
        }
    }

    /// Çalınabilir kayıtlar ("Sen" ve "Diğerleri"): ses silinmediyse ve toplantı kayıtta/işlemede değilse (dosya
    /// yazılıyor olabilir).
    private var playableAudio: [URL] {
        guard !record.audioDeleted, !isLocked else {
            return []
        }
        do {
            let directory: URL = try model.sessionDirectory(id: record.id)
            return [Speaker.others, Speaker.me].compactMap { meetingAudioURL(directory: directory, speaker: $0) }
        } catch {
            meetingsLogger.error("Toplantı klasörü alınamadı, kimlik: \(record.id, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

/// Not: önce sana düşen görevler (vurgulu kart), sonra özet, kararlar, diğer görevler, sözlük.
private struct NoteSections: View {
    let note: MeetingNote
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let mine: [NoteTask] = note.tasks.filter(\.isMine)
        let others: [NoteTask] = note.tasks.filter { !$0.isMine }
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            if mine.isEmpty {
                Label("Sana düşen görev yok.", systemImage: "checkmark.seal")
                    .font(appearance.secondaryFont)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SENİN GÖREVLERİN")
                        .font(DesignTokens.labelFont)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(appearance.accent.color)
                    ForEach(Array(mine.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                        TaskRow(task: item.element)
                    }
                }
                .padding(DesignTokens.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            section(title: "ÖZET") {
                Text(note.summary).textSelection(.enabled)
            }
            if !note.decisions.isEmpty {
                section(title: "KARARLAR") {
                    ForEach(Array(note.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                        Text("• " + item.element).textSelection(.enabled)
                    }
                }
            }
            if !others.isEmpty {
                section(title: "DİĞER GÖREVLER") {
                    ForEach(Array(others.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                        TaskRow(task: item.element)
                    }
                }
            }
            if !note.glossary.isEmpty {
                section(title: "SÖZLÜK") {
                    ForEach(Array(note.glossary.enumerated()), id: \.offset) { (item: (offset: Int, element: GlossaryEntry)) in
                        let term: Text = Text(item.element.term).fontWeight(.semibold)
                        Text("\(term) — \(item.element.meaning)").textSelection(.enabled)
                    }
                }
            }
        }
        // Özet sekmesi transkriptle aynı metin ayarlarını kullanır (Ayarlar › Görünüm); bölüm başlıkları kendi yazı tipinde.
        .font(appearance.bodyFont)
        .lineSpacing(appearance.lineSpacing)
    }

    private func section(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DesignTokens.labelFont)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct TaskRow: View {
    let task: NoteTask
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(task.isMine ? appearance.accent.color : .secondary)
            let owner: Text = Text("\(task.owner): ").fontWeight(.semibold)
            let due: Text = Text(task.dueDate.map { " (\($0))" } ?? "").foregroundStyle(.secondary)
            Text("\(owner)\(task.description)\(due)")
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Konuşmacı N" etiketlerine ad verme ve iki konuşmacıyı birleştirme (ayırma aynı kişiyi ikiye böldüyse).
private struct SpeakerNamesSection: View {
    let model: AppModel
    let record: MeetingRecord
    let isLocked: Bool

    var body: some View {
        // Gösterilen transkriptle aynı bölüm kümesi.
        let persons: [Int] = Array(Set(meetingSegments(record: record).compactMap(\.person))).sorted()
        if !persons.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("KONUŞMACILAR")
                    .font(DesignTokens.labelFont)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(.secondary)
                ForEach(persons, id: \.self) { (person: Int) in
                    HStack(spacing: DesignTokens.Spacing.s) {
                        SpeakerNameField(model: model, meetingID: record.id, person: person, current: record.speakerNames[person] ?? "")
                        if persons.count > 1 {
                            Menu {
                                ForEach(persons.filter { $0 != person }, id: \.self) { (target: Int) in
                                    Button(record.speakerNames[target].map { "\($0) (\(speakerLabel(speaker: .others, person: target)))" } ?? speakerLabel(speaker: .others, person: target)) {
                                        model.mergeSpeakers(meetingID: record.id, from: person, into: target)
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.triangle.merge")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .foregroundStyle(.secondary)
                            .hoverHint("Başka konuşmacıyla birleştir", alignment: .trailing, edge: .bottom)
                        }
                    }
                    .disabled(isLocked)
                }
            }
        }
    }
}

private struct SpeakerNameField: View {
    let model: AppModel
    let meetingID: String
    let person: Int
    let current: String
    @State private var name: String = ""

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Circle().fill(personColor(person: person)).frame(width: 7, height: 7)
            Text("Konuşmacı \(person)").frame(width: 96, alignment: .leading)
            TextField("Ad (ör. Aino)", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.renameSpeaker(meetingID: meetingID, person: person, name: name) }
        }
        .onAppear { name = current }
    }
}

/// Paragraflı transkript (aynı konuşmacının art arda bölümleri tek paragraf, yankı süzülmüş); altında Türkçesi.
/// Çalarken şarkı sözü gibi akar: çalan paragrafta söylenen kelimeler parlak, o anki kelime vurgu renginde, gelecek
/// kelimeler soluk; çalan paragraf ortaya kaydırılır. Paragrafa tıklayınca oradan çalar.
private struct TranscriptSection: View {
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    let player: MeetingAudioPlayer
    let proxy: ScrollViewProxy
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let isActivePlayer: Bool = player.meetingID == record.id
        let time: Double = player.currentTime
        LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            if let error = player.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            ForEach(paragraphs) { (paragraph: TranscriptParagraph) in
                let isActive: Bool = isActivePlayer && time >= paragraph.startSec && time < paragraph.endSec + 0.4
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(dotColor(paragraph: paragraph)).frame(width: 6, height: 6)
                        Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames)).fontWeight(.semibold)
                        Text(timestamp(seconds: paragraph.startSec)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    paragraphText(paragraph: paragraph, isActive: isActive, time: time)
                        .font(appearance.bodyFont)
                        .lineSpacing(appearance.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                    if let turkish = paragraph.turkish {
                        Text(turkish)
                            .font(appearance.secondaryFont)
                            .lineSpacing(appearance.lineSpacing)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isActive ? appearance.accent.color.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .onTapGesture { onPlay(paragraph.startSec) }
                .hoverHint("Buradan dinle", alignment: .trailing, edge: .top)
                .id(paragraph.id)
            }
        }
        // Çalan paragraf değişince ortaya kaydır (şarkı sözü gibi).
        .onChange(of: activeParagraphID(time: time, isActivePlayer: isActivePlayer)) { (_: String?, id: String?) in
            if let id, player.isPlaying {
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Çalan paragraf: anın içinde kaldığı ilk paragraf ("Diğerleri" önce; aynı anda konuşulduysa).
    private func activeParagraphID(time: Double, isActivePlayer: Bool) -> String? {
        guard isActivePlayer else {
            return nil
        }
        return paragraphs.first { time >= $0.startSec && time < $0.endSec + 0.4 }?.id
    }

    /// Çalan paragrafta kelime kelime renk: söylenenler parlak, o anki vurgu renginde, gelecekler soluk.
    private func paragraphText(paragraph: TranscriptParagraph, isActive: Bool, time: Double) -> Text {
        guard isActive, !paragraph.words.isEmpty else {
            return Text(paragraph.text)
        }
        let active: Int? = activeWordIndex(words: paragraph.words, timeSec: time)
        return paragraph.words.enumerated().reduce(Text("")) { (combined: Text, item: (offset: Int, element: StoredWord)) -> Text in
            let separator: String = item.offset == 0 ? "" : " "
            let word: Text = switch active {
            case .some(let index) where item.offset == index:
                Text(item.element.text).foregroundColor(appearance.accent.color).fontWeight(.semibold)
            case .some(let index) where item.offset < index:
                Text(item.element.text).foregroundColor(.primary)
            default:
                Text(item.element.text).foregroundColor(Color.primary.opacity(0.45))
            }
            return Text("\(combined)\(separator)\(word)")
        }
    }

    private func dotColor(paragraph: TranscriptParagraph) -> Color {
        switch (paragraph.speaker, paragraph.person) {
        case (_, .some(let person)): personColor(person: person)
        case (.me, nil): DesignTokens.meColor
        case (.others, nil): .secondary
        }
    }
}

/// Spotify tarzı çalma çubuğu: çalan konuşmacı ve sözü, konum çubuğu ve süreler, 10 sn geri / oynat-duraklat /
/// 10 sn ileri, hız ve kapat.
private struct NowPlayingBar: View {
    let player: MeetingAudioPlayer
    let paragraphs: [TranscriptParagraph]
    let speakerNames: [Int: String]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let time: Double = player.currentTime
        let current: TranscriptParagraph? = paragraphs.last { $0.startSec <= time }
        VStack(spacing: 8) {
            HStack(spacing: DesignTokens.Spacing.s) {
                if let current {
                    Circle()
                        .fill(current.person.map { personColor(person: $0) } ?? (current.speaker == .me ? DesignTokens.meColor : Color.secondary))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(paragraphLabel(paragraph: current, speakerNames: speakerNames))
                            .font(.system(size: 12, weight: .semibold))
                        Text(current.turkish ?? current.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DesignTokens.Spacing.s)
                Button {
                    player.cycleRate()
                } label: {
                    Text(rateText(rate: player.rate))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .hoverHint("Çalma hızı", alignment: .trailing, edge: .top)
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverHint("Çalmayı kapat", alignment: .trailing, edge: .top)
            }
            VStack(spacing: 2) {
                Slider(
                    value: Binding<Double>(get: { player.currentTime }, set: { (value: Double) -> Void in player.seek(to: value) }),
                    in: 0...max(player.duration, 0.1)
                )
                .controlSize(.small)
                .tint(appearance.accent.color)
                .accessibilityLabel("Konum")
                HStack {
                    Text(timestamp(seconds: time))
                    Spacer()
                    Text("-" + timestamp(seconds: max(0, player.duration - time)))
                }
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                Button {
                    player.skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 17, weight: .medium))
                }
                .buttonStyle(.plain)
                .hoverHint("10 sn geri", alignment: .center, edge: .top)
                Button {
                    player.togglePause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(appearance.accent.color, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Duraklat" : "Oynat")
                Button {
                    player.skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10").font(.system(size: 17, weight: .medium))
                }
                .buttonStyle(.plain)
                .hoverHint("10 sn ileri", alignment: .center, edge: .top)
            }
        }
        .padding(DesignTokens.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.bottom, DesignTokens.Spacing.m)
    }
}

/// "1×", "1,25×" (arayüz diline göre ondalık ayırıcı).
private func rateText(rate: Float) -> String {
    Double(rate).formatted(.number.precision(.fractionLength(0...2)).locale(interfaceLocale())) + "×"
}

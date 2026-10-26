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
                Text("\(model.meetingLoadFailures.count) toplantı okunamadı: " + model.meetingLoadFailures.map(\.folder).joined(separator: ", "))
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
                    Text(record.startedAt.formatted(turkishDate(date: .abbreviated)))
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

/// Türkçe tarih + saat biçimi (uygulama dili İngilizce kalsa da tarihler Türkçe görünür).
private func turkishDate(date: Date.FormatStyle.DateStyle) -> Date.FormatStyle {
    Date.FormatStyle(date: date, time: .shortened).locale(Locale(identifier: "tr_TR"))
}

/// Liste ve ayrıntıda gösterilen durum; tamamlanmışsa nil.
private func statusText(record: MeetingRecord, isProcessing: Bool) -> String? {
    if isProcessing {
        return "Not hazırlanıyor…"
    }
    switch record.status {
    case .recording: return "Kayıtta"
    case .processing: return "Not hazırlanıyor…"
    case .done: return nil
    case .failed: return "Hata"
    case .interrupted: return "Yarıda kaldı"
    }
}

// MARK: Ayrıntı

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

    private var isProcessing: Bool {
        model.processingMeetingIDs.contains(record.id)
    }

    /// Kayıtta ya da işlemede: değiştiren eylemler kapalı.
    private var isLocked: Bool {
        model.isLocked(meetingID: record.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                header
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
                if let note = record.note {
                    NoteSections(note: note)
                }
                SpeakerNamesSection(model: model, record: record, isLocked: isLocked)
                // Paragraflar burada bir kez hesaplanır: çalma sırasında (saniyede 4 güncelleme) yeniden süzülmez.
                TranscriptSection(record: record, paragraphs: transcriptParagraphs(record: record), player: player, audioURLs: playableAudio)
            }
            .padding(DesignTokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if player.meetingID == record.id {
                PlayerBar(player: player, speakerName: player.speaker.map { speakerLabel(speaker: $0, person: nil) } ?? "")
            }
        }
        .onDisappear { player.stop() }
        // Saklama süresi sesi bu sayfa açıkken silebilir.
        .onChange(of: record.audioDeleted) { (_: Bool, deleted: Bool) in
            if deleted {
                player.stop()
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Button("PDF", systemImage: "doc.richtext") { exportPDF() }
                    .help("Temiz bir PDF olarak İndirilenler'e kaydet")
                Button("Markdown", systemImage: "square.and.arrow.down") { exportMarkdown() }
                    .help("Markdown olarak İndirilenler'e kaydet")
                Button("Kopyala", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meetingMarkdown(record: record), forType: .string)
                    export = .copied
                }
                .help("Markdown olarak panoya kopyala")
            }
            HStack(spacing: DesignTokens.Spacing.s) {
                Button("Notu yenile", systemImage: "sparkles") {
                    model.regenerateNote(meetingID: record.id)
                }
                .disabled(isLocked)
                .help("Konuşmacı adlarıyla notu yeniden yazar; ses gerekmez.")
                Button("Tekrar işle", systemImage: "arrow.clockwise") {
                    model.reprocess(meetingID: record.id)
                }
                .disabled(isLocked || record.audioDeleted)
                .help("Kaydın tamamından son geçişi ve notu yeniden yapar.")
                Button("Sesi sil", systemImage: "trash", role: .destructive) {
                    player.stop()
                    model.deleteAudio(meetingID: record.id)
                }
                .disabled(isLocked || record.audioDeleted)
            }
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

    /// Çalınabilir kayıtlar: ses silinmediyse ve toplantı kayıtta/işlemede değilse (dosya yazılıyor olabilir).
    private var playableAudio: [Speaker: URL] {
        guard !record.audioDeleted, !isLocked else {
            return [:]
        }
        do {
            let directory: URL = try model.sessionDirectory(id: record.id)
            return [Speaker.me, Speaker.others].reduce(into: [Speaker: URL]()) { (urls: inout [Speaker: URL], speaker: Speaker) -> Void in
                urls[speaker] = meetingAudioURL(directory: directory, speaker: speaker)
            }
        } catch {
            meetingsLogger.error("Toplantı klasörü alınamadı, kimlik: \(record.id, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            return [:]
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
                    .font(.callout)
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
    }

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(task.isMine ? DesignTokens.meColor : .secondary)
            let owner: Text = Text("\(task.owner): ").fontWeight(.semibold)
            let due: Text = Text(task.dueDate.map { " (\($0))" } ?? "").foregroundStyle(.secondary)
            Text("\(owner)\(task.description)\(due)")
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Konuşmacı N" etiketlerine ad verme.
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
                    SpeakerNameField(model: model, meetingID: record.id, person: person, current: record.speakerNames[person] ?? "")
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
/// Zaman damgasına tıklayınca o andan çalar; çalan paragraf vurgulanır.
private struct TranscriptSection: View {
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    let player: MeetingAudioPlayer
    let audioURLs: [Speaker: URL]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            Text("TRANSKRİPT")
                .font(DesignTokens.labelFont)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(.secondary)
            if let error = player.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            ForEach(paragraphs) { (paragraph: TranscriptParagraph) in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(dotColor(paragraph: paragraph)).frame(width: 6, height: 6)
                        Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames)).fontWeight(.semibold)
                        if let url = audioURLs[paragraph.speaker] {
                            Button {
                                player.play(url: url, meetingID: record.id, speaker: paragraph.speaker, startSec: paragraph.startSec)
                            } label: {
                                Label(timestamp(seconds: paragraph.startSec), systemImage: isPlaying(paragraph: paragraph) ? "speaker.wave.2.fill" : "play.fill")
                                    .monospacedDigit()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(isPlaying(paragraph: paragraph) ? DesignTokens.meColor : .secondary)
                            .help("Bu andan çal")
                            .accessibilityLabel("\(timestamp(seconds: paragraph.startSec)) anından çal")
                        } else {
                            Text(timestamp(seconds: paragraph.startSec)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                    Text(paragraph.text)
                        .font(appearance.bodyFont)
                        .lineSpacing(appearance.lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let turkish = paragraph.turkish {
                        Text(turkish)
                            .font(appearance.secondaryFont)
                            .lineSpacing(appearance.lineSpacing)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, isPlaying(paragraph: paragraph) ? 8 : 0)
                .overlay(alignment: .leading) {
                    if isPlaying(paragraph: paragraph) {
                        Capsule().fill(DesignTokens.meColor).frame(width: 3)
                    }
                }
            }
        }
    }

    /// Çalan kayıt bu paragrafın konuşmacısı ve konum paragrafın içinde mi.
    private func isPlaying(paragraph: TranscriptParagraph) -> Bool {
        player.meetingID == record.id && player.speaker == paragraph.speaker
            && player.currentTime >= paragraph.startSec && player.currentTime < paragraph.endSec
    }

    private func dotColor(paragraph: TranscriptParagraph) -> Color {
        switch (paragraph.speaker, paragraph.person) {
        case (_, .some(let person)): personColor(person: person)
        case (.me, nil): DesignTokens.meColor
        case (.others, nil): .secondary
        }
    }
}

/// Çalma çubuğu: oynat/duraklat, konum, süre, kapat.
private struct PlayerBar: View {
    let player: MeetingAudioPlayer
    let speakerName: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            Button {
                player.togglePause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Duraklat" : "Oynat")
            Text(speakerName)
                .font(DesignTokens.labelFont)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding<Double>(get: { player.currentTime }, set: { (value: Double) -> Void in player.seek(to: value) }),
                in: 0...max(player.duration, 0.1)
            )
            .accessibilityLabel("Konum")
            Text("\(timestamp(seconds: player.currentTime)) / \(timestamp(seconds: player.duration))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                player.stop()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Çalmayı kapat")
        }
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.vertical, DesignTokens.Spacing.s)
        .glassEffect(.regular, in: .capsule)
        .padding(DesignTokens.Spacing.m)
    }
}

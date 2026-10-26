import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Geçmiş toplantılar: arama, not, konuşmacı adlandırma, transkript, dışa aktarma ve ses yönetimi.
struct MeetingsWindow: View {
    let model: AppModel
    @State private var query: String = ""
    @State private var selection: String?

    var body: some View {
        let visible: [MeetingRecord] = filterMeetings(records: model.meetings, query: query)
        NavigationSplitView {
            List(visible, selection: $selection) { (record: MeetingRecord) in
                MeetingRow(record: record, isProcessing: model.processingMeetingIDs.contains(record.id))
                    .tag(record.id)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Toplantılarda ara")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .safeAreaInset(edge: .bottom) {
                if !model.meetingLoadFailures.isEmpty {
                    Text("\(model.meetingLoadFailures.count) toplantı okunamadı: " + model.meetingLoadFailures.map(\.folder).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                }
            }
            .overlay {
                if model.meetings.isEmpty {
                    ContentUnavailableView("Henüz toplantı yok", systemImage: "waveform", description: Text("Kaydı başlatınca toplantılar burada görünür."))
                }
            }
        } detail: {
            if let id = selection, let record = visible.first(where: { $0.id == id }) {
                MeetingDetail(model: model, record: record, isProcessing: model.processingMeetingIDs.contains(id), isLocked: model.isLocked(meetingID: id))
                    // Toplantı değişince ad alanları gibi durumlar sıfırlansın.
                    .id(record.id)
            } else {
                ContentUnavailableView("Bir toplantı seç", systemImage: "doc.text")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { model.reloadMeetings() }
    }
}

/// Liste satırı: başlık, tarih ve durum.
private struct MeetingRow: View {
    let record: MeetingRecord
    let isProcessing: Bool

    var body: some View {
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
        .padding(.vertical, 3)
    }
}

/// Türkçe tarih + saat biçimi (uygulama dili İngilizce kalsa da tarihler Türkçe görünür).
private func turkishDate(date: Date.FormatStyle.DateStyle) -> Date.FormatStyle {
    Date.FormatStyle(date: date, time: .shortened).locale(Locale(identifier: "tr_TR"))
}

/// Liste ve ayrıntıda gösterilen durum; tamamlanmışsa nil.
private func statusText(record: MeetingRecord, isProcessing: Bool) -> String? {
    if isProcessing {
        return "İşleniyor…"
    }
    switch record.status {
    case .recording: return "Kayıtta"
    case .processing: return "İşleniyor…"
    case .done: return nil
    case .failed: return "Hata"
    case .interrupted: return "Yarıda kaldı"
    }
}

/// Seçili toplantının ayrıntısı.
private struct MeetingDetail: View {
    let model: AppModel
    let record: MeetingRecord
    let isProcessing: Bool
    /// Kayıtta ya da işlemede: değiştiren eylemler kapalı.
    let isLocked: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                header
                if let message = record.failureMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let note = record.note {
                    NoteSection(note: note)
                }
                SpeakerNamesSection(model: model, record: record, isLocked: isLocked)
                TranscriptSection(record: record)
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text(record.note?.title ?? record.title)
                .font(.system(size: 22, weight: .semibold))
                .textSelection(.enabled)
            HStack(spacing: DesignTokens.Spacing.s) {
                Text(record.startedAt.formatted(turkishDate(date: .long)))
                if let language = record.language {
                    Text("· " + languageName(language: language))
                }
                if let status = statusText(record: record, isProcessing: isProcessing) {
                    Text("· " + status)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.Spacing.s) {
                Button("Markdown kopyala", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meetingMarkdown(record: record), forType: .string)
                }
                Button("Markdown kaydet…", systemImage: "square.and.arrow.down") {
                    saveMarkdown(record: record)
                }
                Button("Notu yeniden oluştur", systemImage: "sparkles") {
                    model.regenerateNote(meetingID: record.id)
                }
                .disabled(isLocked)
                .help("Konuşmacı adlarıyla notu yeniden yazar; ses gerekmez.")
                Button("Tekrar işle", systemImage: "arrow.clockwise") {
                    model.reprocess(meetingID: record.id)
                }
                .disabled(isLocked || record.audioDeleted)
                Button("Sesi sil", systemImage: "trash", role: .destructive) {
                    model.deleteAudio(meetingID: record.id)
                }
                .disabled(isLocked || record.audioDeleted)
            }
            .controlSize(.small)
            if record.audioDeleted {
                Text("Ses dosyaları silindi; metin ve not duruyor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Markdown'ı kullanıcının seçtiği yere kaydeder.
@MainActor
private func saveMarkdown(record: MeetingRecord) {
    let panel: NSSavePanel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = "\(record.note?.title ?? record.title).md"
    NSApplication.shared.activate()
    guard panel.runModal() == .OK, let url = panel.url else {
        return
    }
    do {
        try meetingMarkdown(record: record).write(to: url, atomically: true, encoding: .utf8)
    } catch {
        let alert: NSAlert = NSAlert(error: error)
        alert.runModal()
    }
}

/// Not: özet, kararlar, görevler (kullanıcınınkiler vurgulu), sözlük.
private struct NoteSection: View {
    let note: MeetingNote

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            section(title: "ÖZET") {
                Text(note.summary).textSelection(.enabled)
            }
            if !note.decisions.isEmpty {
                section(title: "KARARLAR") {
                    ForEach(Array(note.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                        Text("• " + item.element)
                    }
                }
            }
            if !note.tasks.isEmpty {
                section(title: "GÖREVLER") {
                    ForEach(Array(note.tasks.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.element.isMine ? "star.fill" : "circle")
                                .font(.system(size: 9))
                                .foregroundStyle(item.element.isMine ? DesignTokens.meColor : .secondary)
                            let owner: Text = Text("\(item.element.owner): ").fontWeight(.semibold)
                            let due: Text = Text(item.element.dueDate.map { " (\($0))" } ?? "").foregroundStyle(.secondary)
                            Text("\(owner)\(item.element.description)\(due)")
                        }
                    }
                }
            }
            if !note.glossary.isEmpty {
                section(title: "SÖZLÜK") {
                    ForEach(Array(note.glossary.enumerated()), id: \.offset) { (item: (offset: Int, element: GlossaryEntry)) in
                        let term: Text = Text(item.element.term).fontWeight(.semibold)
                        Text("\(term) — \(item.element.meaning)")
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

/// "Konuşmacı N" etiketlerine ad verme.
private struct SpeakerNamesSection: View {
    let model: AppModel
    let record: MeetingRecord
    let isLocked: Bool

    var body: some View {
        // Gösterilen transkriptle aynı bölüm kümesi.
        let shown: [StoredSegment] = record.finalSegments.isEmpty ? record.liveSegments : record.finalSegments
        let persons: [Int] = Array(Set(shown.compactMap(\.person))).sorted()
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
            Text("Konuşmacı \(person)").frame(width: 110, alignment: .leading)
            TextField("Ad (ör. Aino)", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onSubmit { model.renameSpeaker(meetingID: meetingID, person: person, name: name) }
        }
        .onAppear { name = current }
    }
}

/// Son geçiş (varsa) + "Sen" bölümleri, zamana göre; altında Türkçesi.
private struct TranscriptSection: View {
    let record: MeetingRecord

    var body: some View {
        let segments: [StoredSegment] = (record.finalSegments.isEmpty
            ? record.liveSegments
            : record.finalSegments + record.liveSegments.filter { $0.speaker == .me })
            .sorted { $0.startSec < $1.startSec }
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            Text("TRANSKRİPT")
                .font(DesignTokens.labelFont)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(.secondary)
            ForEach(segments, id: \.key) { (segment: StoredSegment) in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(timestamp(seconds: segment.startSec)).monospacedDigit().foregroundStyle(.secondary)
                        Text(storedLabel(segment: segment, speakerNames: record.speakerNames)).fontWeight(.semibold)
                    }
                    .font(.system(size: 11))
                    Text(segment.text).textSelection(.enabled)
                    if let turkish = record.translations[segment.key] {
                        Text(turkish).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

import AINotepadCore
import AINotepadUI
import AppKit
import os
import SwiftUI

private let meetingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Meetings")

// MARK: Liste

/// Toplantı listesi (ana pencerenin Toplantılar bölümünde solda): arama ve yeniden eskiye liste.
struct MeetingsListPage: View {
    let model: AppModel
    /// Açık toplantı (satırı vurgulanır).
    let selectedID: String?
    /// Üst çubuktaki arama.
    let query: String
    let onOpen: @MainActor (String) -> Void
    /// Toplu silmeden sonra (açık toplantı silindiyse sayfa kapanır).
    let onDeleted: @MainActor (Set<String>) -> Void
    /// "Seç" modu: satırlara tıklamak toplantıyı açmaz, işaretler.
    @State private var isSelecting: Bool = false
    @State private var checked: Set<String> = []
    @State private var isConfirmingDelete: Bool = false
    @State private var deleteErrors: [String] = []

    var body: some View {
        let visible: [MeetingRecord] = filterMeetings(records: model.meetings, query: query)
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Text(query.isEmpty ? String(localized: "\(model.meetings.count) toplantı") : String(localized: "\(visible.count) sonuç"))
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                if !model.meetings.isEmpty {
                    Button(isSelecting ? "Bitti" : "Seç") { setSelecting(!isSelecting) }
                        .buttonStyle(.pill)
                        .controlSize(.small)
                        .hoverHint("Birden çok toplantıyı seçip sil", alignment: .trailing, edge: .bottom)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, DesignTokens.Spacing.s)
            if model.meetings.isEmpty {
                ContentUnavailableView("Henüz toplantı yok", systemImage: "waveform", description: Text("Kaydı başlatınca toplantılar burada görünür."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { (record: MeetingRecord) in
                            row(record: record)
                                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.s)
                    .animation(.snappy(duration: 0.3), value: visible.map(\.id))
                }
            }
            if isSelecting {
                selectionBar(visible: visible)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !model.meetingLoadFailures.isEmpty {
                Text("\(model.meetingLoadFailures.count) toplantı okunamadı: \(model.meetingLoadFailures.map(\.folder).joined(separator: ", "))")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(.red)
                    .padding(DesignTokens.Spacing.m)
            }
        }
        .animation(.smooth(duration: 0.25), value: isSelecting)
        .animation(.smooth(duration: 0.25), value: isConfirmingDelete)
        .onAppear {
            model.reloadMeetings()
            model.applyRetention()
        }
    }

    /// Satır: seç modunda işaret kutusu ve tıklayınca işaretleme (kayıttaki/işlenen toplantı seçilemez); değilse açma.
    @ViewBuilder
    private func row(record: MeetingRecord) -> some View {
        let isProcessing: Bool = model.processingMeetingIDs.contains(record.id)
        if isSelecting {
            let isChecked: Bool = checked.contains(record.id)
            Button {
                toggle(id: record.id)
            } label: {
                HStack(spacing: DesignTokens.Spacing.s) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .appFont(size: 16, weight: .regular)
                        .foregroundStyle(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.leading, DesignTokens.Spacing.s)
                    MeetingRow(record: record, isProcessing: isProcessing, isSelected: isChecked)
                }
            }
            .buttonStyle(.hoverPlain)
            .disabled(model.isLocked(meetingID: record.id))
        } else {
            Button {
                onOpen(record.id)
            } label: {
                MeetingRow(record: record, isProcessing: isProcessing, isSelected: record.id == selectedID)
            }
            .buttonStyle(.hoverPlain)
        }
    }

    /// Seç modunun alt çubuğu: tümünü seç, sayı, sil; silmede satır içi onay.
    private func selectionBar(visible: [MeetingRecord]) -> some View {
        let selectable: Set<String> = Set(visible.map(\.id).filter { !model.isLocked(meetingID: $0) })
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            ForEach(deleteErrors, id: \.self) { (error: String) in
                Text(error).appFont(size: 11, weight: .regular).foregroundStyle(.red)
            }
            if isConfirmingDelete {
                Text("\(checked.count) toplantı (metin, not ve ses) Çöp Sepeti'ne taşınsın mı?")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(.red)
                HStack(spacing: DesignTokens.Spacing.s) {
                    Button("Sil", role: .destructive) { deleteChecked() }
                    Button("Vazgeç") { isConfirmingDelete = false }
                }
            } else {
                HStack(spacing: DesignTokens.Spacing.s) {
                    Button(checked.isSuperset(of: selectable) && !selectable.isEmpty ? "Seçimi kaldır" : "Tümünü seç") {
                        checked = checked.isSuperset(of: selectable) ? [] : selectable
                    }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                    Text("\(checked.count) seçili")
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Button("Sil", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                        .disabled(checked.isEmpty)
                }
            }
        }
        .controlSize(.small)
        .padding(DesignTokens.Spacing.m)
        .background(Theme.background)
        .overlay(alignment: .top) { Divider() }
    }

    private func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        checked = []
        isConfirmingDelete = false
        deleteErrors = []
    }

    private func toggle(id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if checked.contains(id) {
                checked.remove(id)
            } else {
                checked.insert(id)
            }
        }
    }

    private func deleteChecked() {
        let ids: Set<String> = checked
        withAnimation(.snappy(duration: 0.3)) {
            deleteErrors = model.deleteMeetings(meetingIDs: ids)
            let remaining: Set<String> = Set(model.meetings.map(\.id))
            onDeleted(ids.subtracting(remaining))
            checked = ids.intersection(remaining)
            isConfirmingDelete = false
            if deleteErrors.isEmpty {
                isSelecting = false
            }
        }
    }
}

/// Liste satırı: başlık, tarih, durum ve varsa senin görev sayın.
struct MeetingRow: View {
    let record: MeetingRecord
    let isProcessing: Bool
    let isSelected: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.note?.title ?? record.title)
                    .appFont(size: 13, weight: .semibold)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.startedAt.formatted(interfaceDate(date: .abbreviated)))
                    if let status = statusText(record: record, isProcessing: isProcessing) {
                        Text("· " + status).foregroundStyle(record.status == .failed ? .red : .secondary)
                    }
                }
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            let mine: Int = record.note?.tasks.filter(\.isMine).count ?? 0
            if mine > 0 {
                Label("\(mine)", systemImage: "star.fill")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(.tint)
                    .help("Sana düşen görev sayısı")
            }
            Image(systemName: "chevron.right")
                .appFont(size: 10, weight: .semibold)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, DesignTokens.Spacing.s)
        .background(
            isSelected ? Theme.selected : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
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
    /// "Toplantıyı sil"e basıldı: satır içi onay bekleniyor (ayrı uyarı penceresi yok).
    case confirmDelete
}

/// Seçili toplantının sayfası: önce sana düşen görevler, sonra özet, kararlar, diğer görevler, sözlük,
/// konuşmacı adları ve paragraflı transkript (zaman damgasından çalma).
struct MeetingDetailPage: View {
    let model: AppModel
    let player: MeetingAudioPlayer
    let record: MeetingRecord
    /// Toplantı silinince (sayfa artık gösterilemez) çağrılır.
    let onDeleted: @MainActor () -> Void
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
                    header.zIndex(1)
                    statusLines
                    PillPicker(selection: $tab, options: [(MeetingTab.summary, "Özet"), (MeetingTab.transcript, "Transkript")])
                        .frame(maxWidth: 260)
                    Group {
                    switch tab {
                    case .summary:
                        if let note = record.note {
                            NoteSections(note: note)
                        } else {
                            Text(isProcessing ? "Not hazırlanıyor…" : "Bu toplantının notu yok.")
                                .foregroundStyle(.secondary)
                        }
                    case .transcript:
                        SpeakerNamesSection(
                            model: model, record: record, isLocked: isLocked,
                            onPlay: { (startSec: Double) -> Void in play(from: startSec) }
                        )
                        TranscriptSection(
                            record: record, paragraphs: paragraphs, player: player, proxy: proxy,
                            canPlay: !playableAudio.isEmpty,
                            onPlay: { (startSec: Double) -> Void in play(from: startSec) }
                        )
                    }
                    }
                    // Sekme değişince içerik yumuşakça geçer.
                    .id(tab)
                    .transition(.opacity)
                }
                .animation(.smooth(duration: 0.25), value: tab)
                .animation(.smooth(duration: 0.3), value: model.speakerReviews[record.id])
                .padding(DesignTokens.Spacing.l)
                // Geniş ana pencerede satırlar okunur uzunlukta kalsın (panelde etkisiz).
                .frame(maxWidth: 820, alignment: .leading)
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
        // Yalnızca bu toplantı çalıyorsa durur (aynı çalar başka bir sayfada başka toplantıyı çalıyor olabilir).
        .onDisappear {
            if player.meetingID == record.id {
                player.stop()
            }
        }
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
            .appFont(size: 12, weight: .regular)
        }
        if let message = record.failureMessage {
            Text(message)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let notice = record.notice {
            Label(notice, systemImage: "info.circle")
                .appFont(size: 12, weight: .regular)
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
                .appFont(size: 26, weight: .regular)
                .tracking(-0.4)
                .textSelection(.enabled)
            Text(meetingMetaLine(record: record))
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(.secondary)
            // İpuçları düğmelerin altındaki satırların üstünde çizilsin (birbirine girmesin).
            actions.zIndex(1)
            exportLine
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        .animation(.smooth(duration: 0.25), value: export)
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
                    .buttonStyle(.pillPrimary)
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
                Button("Sesi sil", systemImage: "speaker.slash", role: .destructive) {
                    player.stop()
                    model.deleteAudio(meetingID: record.id)
                }
                .disabled(isLocked || record.audioDeleted)
                .hoverHint("Yalnızca ses dosyalarını sil; metin ve not kalır", alignment: .leading, edge: .bottom)
                Button("Toplantıyı sil", systemImage: "trash", role: .destructive) {
                    export = .confirmDelete
                }
                .disabled(isLocked)
                .hoverHint("Metin, not ve sesle birlikte Çöp Sepeti'ne taşı", alignment: .leading, edge: .bottom)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var exportLine: some View {
        switch export {
        case .none:
            if record.audioDeleted {
                Text("Ses dosyaları silindi; metin ve not duruyor.")
                    .appFont(size: 11, weight: .regular)
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
                        .pointerStyle(.link)
            }
            .appFont(size: 11, weight: .regular)
        case .copied:
            Label("Markdown panoya kopyalandı", systemImage: "checkmark.circle.fill")
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(.red)
        case .confirmDelete:
            HStack(spacing: DesignTokens.Spacing.s) {
                Label("Toplantı (metin, not ve ses) Çöp Sepeti'ne taşınsın mı?", systemImage: "trash")
                    .foregroundStyle(.red)
                Button("Sil", role: .destructive) {
                    player.stop()
                    if let error = model.deleteMeeting(meetingID: record.id) {
                        export = .failed(error)
                    } else {
                        onDeleted()
                    }
                }
                Button("Vazgeç") { export = .none }
            }
            .appFont(size: 11, weight: .regular)
            .controlSize(.small)
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
            meetingsLogger.error("Dışa aktarılamadı, uzantı: \(fileExtension, privacy: .public), hata: \(String(describing: error), privacy: .private)")
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
            meetingsLogger.error("Toplantı klasörü alınamadı, kimlik: \(record.id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
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
                        .appFont(size: 11, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(appearance.accent.color)
                    ForEach(Array(mine.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                        TaskRow(task: item.element)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.accent.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(appearance.accent.color.opacity(0.28)))
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

    /// Bölüm: beyaz kart içinde küçük büyük harfli başlık ve içerik (ElevenLabs kartı).
    private func section(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
    }
}

private struct TaskRow: View {
    let task: NoteTask
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle")
                .appFont(size: 9, weight: .regular)
                .foregroundStyle(task.isMine ? appearance.accent.color : .secondary)
            let owner: Text = Text("\(task.owner): ").fontWeight(.semibold)
            let due: Text = Text(task.dueDate.map { " (\($0))" } ?? "").foregroundStyle(.secondary)
            Text("\(owner)\(task.description)\(due)")
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Konuşmacı N" etiketlerine ad verme, iki konuşmacıyı birleştirme (ayırma aynı kişiyi ikiye böldüyse) ve akıllı
/// modelin ad/birleştirme önerileri ("Gözden geçir").
private struct SpeakerNamesSection: View {
    let model: AppModel
    let record: MeetingRecord
    let isLocked: Bool
    let onPlay: @MainActor (Double) -> Void

    var body: some View {
        // Gösterilen transkriptle aynı bölüm kümesi.
        let persons: [Int] = Array(Set(meetingSegments(record: record).compactMap(\.person))).sorted()
        if !persons.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: DesignTokens.Spacing.s) {
                    Text("KONUŞMACILAR")
                        .appFont(size: 11, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Gözden geçir", systemImage: "sparkles") {
                        model.reviewSpeakers(meetingID: record.id)
                    }
                    .controlSize(.small)
                    .disabled(isLocked || model.speakerReviews[record.id] == .loading)
                    .hoverHint("Transkripti okuyup ad ve birleştirme önerir", alignment: .trailing, edge: .bottom)
                }
                if let state = model.speakerReviews[record.id] {
                    SpeakerReviewCard(model: model, record: record, state: state, isLocked: isLocked, onPlay: onPlay)
                }
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
                            .buttonStyle(.hoverPlain)
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

/// Konuşmacı incelemesinin önerileri: her biri tek tıkla uygulanır ya da reddedilir; şüpheli anlara tıklayınca
/// oradan çalınır. Öneri uygulanınca not eski adlarla kaldığı için "Notu yenile" sunulur.
private struct SpeakerReviewCard: View {
    let model: AppModel
    let record: MeetingRecord
    let state: SpeakerReviewState
    let isLocked: Bool
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Label("Konuşmacı önerileri", systemImage: "sparkles")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Button("Kapat", systemImage: "xmark") { model.closeSpeakerReview(meetingID: record.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(.secondary)
                    .hoverHint("Önerileri kapat", alignment: .trailing, edge: .bottom)
            }
            content
        }
        .padding(DesignTokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.accent.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: DesignTokens.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Transkript okunuyor…").foregroundStyle(.secondary)
            }
            .appFont(size: 12, weight: .regular)
        case .failed(let message):
            Text(message)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .ready(let review, let applied):
            ForEach(review.names) { (suggestion: SpeakerNameSuggestion) in
                suggestionRow(
                    title: Text("\(label(person: suggestion.person)) → \(suggestion.name)"),
                    reason: suggestion.reason,
                    onAccept: { model.acceptNameSuggestion(meetingID: record.id, suggestion: suggestion) },
                    onDismiss: { model.dismissNameSuggestion(meetingID: record.id, suggestion: suggestion) }
                )
            }
            ForEach(review.merges) { (suggestion: SpeakerMergeSuggestion) in
                suggestionRow(
                    title: Text("\(label(person: suggestion.from)) ile \(label(person: suggestion.into)) aynı kişi"),
                    reason: suggestion.reason,
                    onAccept: { model.acceptMergeSuggestion(meetingID: record.id, suggestion: suggestion) },
                    onDismiss: { model.dismissMergeSuggestion(meetingID: record.id, suggestion: suggestion) }
                )
            }
            if !review.suspicious.isEmpty {
                Text("KONTROL ET")
                    .appFont(size: 11, weight: .semibold)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(.secondary)
                    .padding(.top, DesignTokens.Spacing.xs)
                ForEach(review.suspicious) { (passage: SuspiciousPassage) in
                    suspiciousRow(passage: passage)
                }
            }
            if !review.hasPendingSuggestions && review.suspicious.isEmpty && applied == 0 {
                Text("Öneri yok: transkriptte ad ya da birleştirme için yeterli ipucu bulunamadı.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(.secondary)
            }
            if applied > 0 {
                HStack(spacing: DesignTokens.Spacing.s) {
                    Text("Not eski adlarla yazıldı.")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(.secondary)
                    Button("Notu yenile", systemImage: "sparkles") { model.regenerateNote(meetingID: record.id) }
                        .controlSize(.small)
                        .disabled(isLocked)
                }
                .padding(.top, DesignTokens.Spacing.xs)
            }
        }
    }

    /// Konuşmacının şu anki adı ve numarası: "Aino (Konuşmacı 2)" ya da "Konuşmacı 2".
    private func label(person: Int) -> String {
        let number: String = speakerLabel(speaker: .others, person: person)
        return record.speakerNames[person].map { "\($0) (\(number))" } ?? number
    }

    private func suggestionRow(title: Text, reason: String, onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                title.font(appearance.bodyFont.weight(.medium))
                Text(reason)
                    .font(appearance.secondaryFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Uygula", systemImage: "checkmark", action: onAccept)
                .labelStyle(.iconOnly)
                .buttonStyle(.pillPrimary)
                .controlSize(.small)
                .disabled(isLocked)
                .hoverHint("Öneriyi uygula", alignment: .trailing, edge: .bottom)
            Button("Reddet", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .hoverHint("Öneriyi reddet", alignment: .trailing, edge: .bottom)
        }
    }

    @ViewBuilder
    private func suspiciousRow(passage: SuspiciousPassage) -> some View {
        let row: some View = HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s) {
            Text(passage.time)
                .appFont(size: 11, weight: .regular).monospacedDigit()
                .foregroundStyle(.tint)
            Text(passage.note)
                .font(appearance.secondaryFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let seconds = timestampSeconds(text: passage.time), !record.audioDeleted {
            Button { onPlay(seconds) } label: { row }
                .buttonStyle(.hoverPlain)
                .hoverHint("Bu andan dinle", alignment: .leading, edge: .bottom)
        } else {
            row
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
        // Birleştirme ya da başka bir yerden ad değişirse alan güncellenir (eski ad yazılıp silinmesin).
        .onChange(of: current) { (_: String, value: String) in name = value }
    }
}

/// Ses varsa paragraf tıklanabilir (el imleci, hover, "Buradan dinle"); yoksa düz metin (tıklanabilir görünmesin).
private struct PlayableParagraph: ViewModifier {
    let canPlay: Bool
    let onTap: @MainActor () -> Void

    func body(content: Content) -> some View {
        if canPlay {
            content
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
                .hoverHighlight(cornerRadius: 8)
                .hoverHint("Buradan dinle", alignment: .trailing, edge: .top)
        } else {
            content
        }
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
    /// Ses var (silinmemiş, kayıtta değil): paragrafa tıklayınca oradan çalar.
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let isActivePlayer: Bool = player.meetingID == record.id
        let time: Double = player.currentTime
        LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            if let error = player.errorMessage {
                Text(error).appFont(size: 11, weight: .regular).foregroundStyle(.red)
            }
            ForEach(paragraphs) { (paragraph: TranscriptParagraph) in
                let isActive: Bool = isActivePlayer && time >= paragraph.startSec && time < paragraph.endSec + 0.4
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(dotColor(paragraph: paragraph)).frame(width: 6, height: 6)
                        Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames)).fontWeight(.semibold)
                        Text(timestamp(seconds: paragraph.startSec)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .appFont(size: 11, weight: .regular)
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
                .modifier(PlayableParagraph(canPlay: canPlay) { onPlay(paragraph.startSec) })
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
        return Text(karaokeText(words: paragraph.words, activeIndex: activeWordIndex(words: paragraph.words, timeSec: time), accent: appearance.accent.color))
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
                            .appFont(size: 12, weight: .semibold)
                        Text(current.turkish ?? current.text)
                            .appFont(size: 11, weight: .regular)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DesignTokens.Spacing.s)
                Button {
                    player.cycleRate()
                } label: {
                    Text(rateText(rate: player.rate))
                        .appFont(size: 11, weight: .semibold)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.soft, in: Capsule())
                }
                .buttonStyle(.hoverCapsule)
                .hoverHint("Çalma hızı", alignment: .trailing, edge: .top)
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 11, weight: .semibold)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.hoverPlain)
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
                .appFont(size: 10, weight: .regular)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                Button {
                    player.skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10").appFont(size: 17, weight: .medium)
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("10 sn geri", alignment: .center, edge: .top)
                Button {
                    player.togglePause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .appFont(size: 17, weight: .bold)
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(appearance.accent.color, in: Circle())
                }
                .buttonStyle(.hoverCapsule)
                .accessibilityLabel(player.isPlaying ? "Duraklat" : "Oynat")
                Button {
                    player.skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10").appFont(size: 17, weight: .medium)
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("10 sn ileri", alignment: .center, edge: .top)
            }
        }
        .padding(DesignTokens.Spacing.m)
        .cardSurface(cornerRadius: 18)
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.bottom, DesignTokens.Spacing.m)
    }
}

/// "1×", "1,25×" (arayüz diline göre ondalık ayırıcı).
private func rateText(rate: Float) -> String {
    Double(rate).formatted(.number.precision(.fractionLength(0...2)).locale(interfaceLocale())) + "×"
}

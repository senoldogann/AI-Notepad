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
                if model.importingCount > 0 {
                    ProgressView().controlSize(.small)
                }
                Button("İçe aktar", systemImage: "square.and.arrow.down.on.square") { chooseMediaToImport(model: model) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.pill)
                    .controlSize(.small)
                    .hoverHint("Ses ya da video dosyasından toplantı (sürükleyip bırakabilirsin)", alignment: .trailing, edge: .bottom)
                if !model.meetings.isEmpty {
                    Button(isSelecting ? "Bitti" : "Seç") { setSelecting(!isSelecting) }
                        .buttonStyle(.pill)
                        .controlSize(.small)
                        .hoverHint("Birden çok toplantıyı seçip sil", alignment: .trailing, edge: .bottom)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, DesignTokens.Spacing.s)
            if let error = model.importError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(.red)
                    .padding(.horizontal, DesignTokens.Spacing.m)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.meetings.isEmpty {
                EmptyStatePlaceholder(symbol: "waveform", title: "Henüz toplantı yok", message: "Kaydı başlatınca ya da bir ses/video dosyasını buraya sürükleyince toplantılar burada görünür.")
            } else if visible.isEmpty {
                EmptyStatePlaceholder(symbol: "magnifyingglass", title: "Eşleşen toplantı yok", message: "Başlıkta, notta ya da metinde başka bir kelimeyle ara.")
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
    /// Özetin gösterildiği dil: nil Türkçe not, değilse paylaşım sürümü.
    @State private var noteLanguage: ShareLanguage?

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
                    // İpuçları kapağın altındaki satırların üstünde çizilsin (birbirine girmesin).
                    hero(paragraphs: paragraphs).zIndex(1)
                    exportLine
                        .transition(.move(edge: .top).combined(with: .opacity))
                    statusLines
                    PillPicker(selection: $tab, options: [(MeetingTab.summary, "Özet"), (MeetingTab.transcript, "Transkript")])
                        .frame(maxWidth: 260)
                    Group {
                    switch tab {
                    case .summary:
                        if let note = record.note {
                            PillPicker(selection: $noteLanguage, options: [
                                (nil, "Türkçe"), (ShareLanguage.finnish, "Suomi"), (ShareLanguage.english, "English"),
                            ])
                            .fixedSize()
                            .hoverHint("İş arkadaşlarına göndermek için notun Fince ya da İngilizce sürümü", alignment: .leading, edge: .bottom)
                            if let language = noteLanguage {
                                // Dil değişince durum (hata, deneme) sıfırlansın.
                                SharedNoteSection(model: model, record: record, note: note, language: language)
                                    .id(language)
                            } else {
                                SummaryTab(
                                    model: model, note: note, record: record, paragraphs: paragraphs, canPlay: !playableAudio.isEmpty,
                                    onPlay: { (startSec: Double) -> Void in play(from: startSec) }
                                )
                            }
                        } else {
                            if isProcessing {
                                EmptyStateCard(symbol: "hourglass", title: "Not hazırlanıyor…", message: "Bitince özet, kararlar ve görevler burada görünür.")
                            } else {
                                EmptyStateCard(symbol: "doc.text", title: "Bu toplantının notu yok", message: "\"Notu yenile\" ile not yeniden yazılabilir.")
                            }
                        }
                    case .transcript:
                        SpeakerChips(model: model, record: record, isLocked: isLocked, onPlay: { (startSec: Double) -> Void in play(from: startSec) })
                        if paragraphs.isEmpty {
                            EmptyStateCard(symbol: "text.bubble", title: "Bu toplantının metni yok", message: "Kayıt sırasında konuşma algılanmadı.")
                        }
                        TranscriptSection(
                            record: record, paragraphs: paragraphs, player: player, proxy: proxy,
                            canPlay: !playableAudio.isEmpty,
                            onPlay: { (startSec: Double) -> Void in play(from: startSec) },
                            canEdit: !isLocked,
                            onToggleHighlight: { (paragraph: TranscriptParagraph) -> Void in model.toggleHighlight(meetingID: record.id, paragraph: paragraph) }
                        )
                        .frame(maxWidth: 820, alignment: .leading)
                    }
                    }
                    // Sekme değişince içerik yumuşakça geçer.
                    .id(tab)
                    .transition(.opacity)
                }
                .animation(.smooth(duration: 0.25), value: tab)
                .animation(.smooth(duration: 0.25), value: export)
                .animation(.smooth(duration: 0.3), value: model.speakerReviews[record.id])
                .padding(DesignTokens.Spacing.l)
                // Geniş ana pencerede içerik okunur genişlikte kalsın (panelde etkisiz).
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            // Not varsa önce özet: toplantıdan sonra ilk bakılacak şey; yoksa transkript.
            tab = record.note == nil ? .transcript : .summary
            // "--not-dili fi|en": özeti paylaşım dilinde açar (görsel kontrol için).
            if let index = CommandLine.arguments.firstIndex(of: "--not-dili"), CommandLine.arguments.indices.contains(index + 1) {
                noteLanguage = ShareLanguage(rawValue: CommandLine.arguments[index + 1])
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

    /// Kapak: toplantı kartıyla aynı simli gradyan; tarih, başlık, özet çipleri, eylemler ve konuşmacı zaman çizgisi.
    private func hero(paragraphs: [TranscriptParagraph]) -> some View {
        let spans: [SpeakerSpan] = speakerSpans(paragraphs: paragraphs)
        let totalSec: Double = paragraphs.map(\.endSec).max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Text(record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(interfaceLocale())))
                .appFont(size: 12, weight: .medium)
                .tracking(0.6)
                .textCase(.uppercase)
                .opacity(0.85)
            Text(record.note?.title ?? record.title)
                .appFont(size: 30, weight: .regular)
                .tracking(-0.6)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(.top, 8)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(heroChips(paragraphs: paragraphs), id: \.self) { (chip: String) in
                    Text(chip)
                        .appFont(size: 12, weight: .medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22)))
                }
            }
            .padding(.top, 12)
            heroActions.padding(.top, 20)
            if !spans.isEmpty, totalSec > 0 {
                SpeakerTimeline(
                    spans: spans, totalSec: totalSec, player: player, meetingID: record.id, canPlay: !playableAudio.isEmpty,
                    onSeek: { (startSec: Double) -> Void in play(from: startSec) }
                )
                .padding(.top, 18)
            }
        }
        .foregroundStyle(.white)
        .padding(EdgeInsets(top: 24, leading: 26, bottom: 18, trailing: 26))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Yalnızca zemin kırpılır: düğme ipuçları kapağın dışına taşabilsin.
        .background {
            LivingCoverBackground(seed: record.id)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .environment(\.colorScheme, .dark)
    }

    /// Kapaktaki çipler: süre, dil, konuşmacı, karar ve terim sayısı (olanlar).
    private func heroChips(paragraphs: [TranscriptParagraph]) -> [String] {
        let speakers: Int = speakerShares(paragraphs: paragraphs).count
        let decisions: Int = record.note?.decisions.count ?? 0
        let terms: Int = record.note?.glossary.count ?? 0
        return (meetingDurationMinutes(record: record).map { [String(localized: "\($0) dk")] } ?? [])
            + (record.language.map { [meetingLanguageName(language: $0)] } ?? [])
            // İngilizcede tekil ayrı yazılır ("1 speaker").
            + (speakers == 1 ? [String(localized: "1 konuşmacı")] : speakers > 1 ? [String(localized: "\(speakers) konuşmacı")] : [])
            + (decisions == 1 ? [String(localized: "1 karar")] : decisions > 1 ? [String(localized: "\(decisions) karar")] : [])
            + (terms == 1 ? [String(localized: "1 terim")] : terms > 1 ? [String(localized: "\(terms) terim")] : [])
    }

    /// Kapaktaki eylemler: "Dinle" ve "Notu yenile" görünür; dışa aktarma simge; yönetim "⋯" menüsünde. Dar panelde
    /// "Dinle" dışındaki her şey menüye toplanır.
    private var heroActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.s) {
                listenButton
                Button("Notu yenile", systemImage: "sparkles") { model.regenerateNote(meetingID: record.id) }
                    .buttonStyle(.coverGlass)
                    .disabled(isLocked)
                    .hoverHint("Notu adlarla yeniden yaz", alignment: .leading, edge: .bottom)
                Spacer(minLength: DesignTokens.Spacing.s)
                if let text = displayedShareText {
                    ShareLink(item: text, subject: Text(record.note?.title ?? record.title)) {
                        Label("Paylaş", systemImage: "square.and.arrow.up")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.coverGlass)
                    .hoverHint("Notu paylaş (Mail, Mesajlar, Notlar…); seçili dilde", alignment: .trailing, edge: .bottom)
                }
                Button("PDF", systemImage: "doc.richtext") { exportPDF() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.coverGlass)
                    .hoverHint("PDF olarak İndirilenler'e kaydet", alignment: .trailing, edge: .bottom)
                Button("Markdown", systemImage: "square.and.arrow.down") { exportMarkdown() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.coverGlass)
                    .hoverHint("Markdown olarak kaydet", alignment: .trailing, edge: .bottom)
                Button("Kopyala", systemImage: "doc.on.doc") { copyMarkdown() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.coverGlass)
                    .hoverHint("Markdown olarak kopyala", alignment: .trailing, edge: .bottom)
                moreMenu { manageItems }
            }
            HStack(spacing: DesignTokens.Spacing.s) {
                listenButton
                Spacer(minLength: DesignTokens.Spacing.s)
                moreMenu {
                    exportItems
                    Divider()
                    manageItems
                }
            }
        }
    }

    /// Baştan dinle; bu toplantı çalıyorsa duraklat/sürdür.
    @ViewBuilder
    private var listenButton: some View {
        if !playableAudio.isEmpty {
            let isPlayingThis: Bool = player.meetingID == record.id && player.isPlaying
            Button(isPlayingThis ? "Duraklat" : "Dinle", systemImage: isPlayingThis ? "pause.fill" : "play.fill") {
                if player.meetingID == record.id {
                    player.togglePause()
                } else {
                    play(from: 0)
                }
            }
            .buttonStyle(.bannerPrimary)
            .hoverHint("Baştan dinle; çalan kelime renklenir", alignment: .leading, edge: .bottom)
        }
    }

    /// "⋯" menüsü: kapak üstünde cam daire.
    private func moreMenu(@ViewBuilder items: () -> some View) -> some View {
        Menu {
            items()
        } label: {
            // Simge düğmeleriyle aynı genişlikte daire.
            Image(systemName: "ellipsis").frame(width: 16, height: 16)
        }
        .menuStyle(.button)
        .buttonStyle(.coverGlass)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHint("Diğer işlemler", alignment: .trailing, edge: .bottom)
    }

    /// Dar panelde menüye taşınan not ve dışa aktarma eylemleri.
    @ViewBuilder
    private var exportItems: some View {
        Button("Notu yenile", systemImage: "sparkles") { model.regenerateNote(meetingID: record.id) }
            .disabled(isLocked)
        Button("PDF olarak kaydet", systemImage: "doc.richtext") { exportPDF() }
        Button("Markdown olarak kaydet", systemImage: "square.and.arrow.down") { exportMarkdown() }
        Button("Markdown olarak kopyala", systemImage: "doc.on.doc") { copyMarkdown() }
    }

    /// Yönetim: yeniden işleme ve silme (kilitliyken kapalı); silme satır içinde onay ister.
    @ViewBuilder
    private var manageItems: some View {
        Menu("Şablonla yeniden yaz") {
            ForEach(NoteTemplateKind.allCases, id: \.self) { (kind: NoteTemplateKind) in
                Button {
                    model.regenerateNote(meetingID: record.id, template: NoteTemplate(kind: kind, customInstructions: UserDefaults.standard.string(forKey: SettingsKey.customTemplate) ?? ""))
                } label: {
                    if (record.template?.kind ?? .general) == kind {
                        Label(templateTitle(kind: kind), systemImage: "checkmark")
                    } else {
                        Text(templateTitle(kind: kind))
                    }
                }
            }
        }
        .disabled(isLocked)
        Button("Tekrar işle", systemImage: "arrow.clockwise") { model.reprocess(meetingID: record.id) }
            .disabled(isLocked || record.audioDeleted)
        Divider()
        Button("Sesi sil", systemImage: "speaker.slash", role: .destructive) {
            player.stop()
            model.deleteAudio(meetingID: record.id)
        }
        .disabled(isLocked || record.audioDeleted)
        Button("Toplantıyı sil", systemImage: "trash", role: .destructive) { export = .confirmDelete }
            .disabled(isLocked)
    }

    /// Paylaşılacak metin: seçili dildeki not (paylaşım sürümü henüz yoksa Türkçe); not yoksa nil.
    private var displayedShareText: String? {
        guard let note = record.note else {
            return nil
        }
        if let language = noteLanguage, let shared = record.sharedNotes?[language.rawValue] {
            return shareText(record: record, note: shared, language: language)
        }
        return shareText(record: record, note: note, language: nil)
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meetingMarkdown(record: record), forType: .string)
        export = .copied
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

/// Özet sekmesi bir belge gibi okunur: sana düşen görevler, büyük yazılı özet, numaralı kararlar, diğer görevler ve
/// sözlük; geniş pencerede sağda "Bir bakışta" ve konuşma payları, darda (panel) konuşma payları en altta.
private struct SummaryTab: View {
    let model: AppModel
    let note: MeetingNote
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    /// Ses var: konu akışındaki zamana tıklayınca oradan çalar.
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let shares: [SpeakerShare] = speakerShares(paragraphs: paragraphs)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                main.frame(minWidth: 380, idealWidth: 380, maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 12) {
                    glance(shares: shares)
                    if !shares.isEmpty {
                        talkShare(shares: shares)
                    }
                }
                .frame(width: 250)
            }
            VStack(alignment: .leading, spacing: 30) {
                main
                if !shares.isEmpty {
                    talkShare(shares: shares)
                }
            }
        }
    }

    private var main: some View {
        let mine: [NoteTask] = note.tasks.filter(\.isMine)
        let others: [NoteTask] = note.tasks.filter { !$0.isMine }
        return VStack(alignment: .leading, spacing: 30) {
            if mine.isEmpty {
                EmptyStateCard(symbol: "checkmark.circle", title: "Bu toplantıda sana düşen görev yok", message: nil)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SENİN GÖREVLERİN")
                        .appFont(size: 11, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(appearance.accent.color)
                    ForEach(Array(mine.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                        TaskCard(model: model, record: record, task: item.element)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.accent.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(appearance.accent.color.opacity(0.28)))
            }
            Text(note.summary)
                .font(appearance.font(size: appearance.textSize + 3, weight: .regular))
                .lineSpacing(appearance.lineSpacing + 3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            let marked: [TranscriptParagraph] = paragraphs.filter { isHighlighted(paragraph: $0, highlights: record.highlights ?? []) }
            if !marked.isEmpty {
                section(title: "İŞARETLEDİĞİN ANLAR") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(marked) { (paragraph: TranscriptParagraph) in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Button {
                                    onPlay(paragraph.startSec)
                                } label: {
                                    Label(timestamp(seconds: paragraph.startSec), systemImage: "bookmark.fill")
                                        .appFont(size: 12, weight: .medium)
                                        .monospacedDigit()
                                        .foregroundStyle(appearance.accent.color)
                                }
                                .buttonStyle(.hoverPlain)
                                .disabled(!canPlay)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames))
                                        .appFont(size: 12, weight: .semibold)
                                    Text(paragraph.turkish ?? paragraph.text)
                                        .font(appearance.secondaryFont)
                                        .lineLimit(3)
                                        .foregroundStyle(Theme.ink.opacity(0.85))
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(appearance.accent.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
            if let outline = note.outline, !outline.isEmpty {
                section(title: "KONU AKIŞI") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(outline.enumerated()), id: \.offset) { (item: (offset: Int, element: OutlineItem)) in
                            OutlineRow(item: item.element, isLast: item.offset == outline.count - 1, canPlay: canPlay) {
                                onPlay(item.element.startSec)
                            }
                        }
                    }
                }
            }
            if !note.decisions.isEmpty {
                section(title: "KARARLAR") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(note.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                            VStack(alignment: .leading, spacing: 0) {
                                Rectangle().fill(Theme.line).frame(height: 1)
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(decisionNumber(index: item.offset))
                                        .appFont(size: 22, weight: .light)
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.muted)
                                        .frame(width: 40, alignment: .leading)
                                    Text(item.element)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 12)
                            }
                        }
                    }
                }
            }
            if !others.isEmpty {
                section(title: "DİĞER GÖREVLER") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(others.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                            TaskCard(model: model, record: record, task: item.element)
                        }
                    }
                }
            }
            if !note.glossary.isEmpty {
                GlossarySection(glossary: note.glossary)
            }
        }
        // Özet sekmesi transkriptle aynı metin ayarlarını kullanır (Ayarlar › Görünüm); bölüm başlıkları kendi yazı tipinde.
        .font(appearance.bodyFont)
        .lineSpacing(appearance.lineSpacing)
    }

    /// "Bir bakışta": süre, konuşmacı, karar ve senin görev sayın.
    private func glance(shares: [SpeakerShare]) -> some View {
        let stats: [(value: String, label: LocalizedStringKey)] = [
            (meetingDurationMinutes(record: record).map { String(localized: "\($0) dk") } ?? "–", "süre"),
            ("\(shares.count)", "konuşmacı"),
            ("\(note.decisions.count)", "karar"),
            ("\(note.tasks.filter(\.isMine).count)", "senin görevin"),
        ]
        return asideCard(title: "BİR BAKIŞTA") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(Array(stats.enumerated()), id: \.offset) { (item: (offset: Int, element: (value: String, label: LocalizedStringKey))) in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.element.value).appFont(size: 22, weight: .regular).tracking(-0.4)
                        Text(item.element.label).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    /// Kim ne kadar konuştu: harf rozeti, ad, pay çubuğu ve yüzde.
    private func talkShare(shares: [SpeakerShare]) -> some View {
        asideCard(title: "KİM NE KADAR KONUŞTU") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(shares, id: \.key) { (share: SpeakerShare) in
                    HStack(spacing: 10) {
                        SpeakerAvatar(text: avatarText(key: share.key, speakerNames: record.speakerNames), color: speakerColor(key: share.key), size: 24)
                        Text(speakerName(key: share.key, speakerNames: record.speakerNames))
                            .appFont(size: 13, weight: .regular)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Capsule()
                            .fill(Theme.soft)
                            .frame(width: 56, height: 6)
                            .overlay(alignment: .leading) {
                                Capsule().fill(speakerColor(key: share.key)).frame(width: max(3, 56 * share.fraction), height: 6)
                            }
                        Text(share.fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))
                            .appFont(size: 12, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func asideCard(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }

    /// Bölüm: kart olmadan küçük büyük harfli başlık ve içerik (belge düzeni).
    private func section(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sözlük: açılıp kapanan bölüm. Kapalıyken terim sayısı ve ilk terimler çip olarak; açıkken solda terim sağda anlamı
/// olan, ince çizgilerle ayrılmış liste (dar panelde terim anlamının üstünde). Açık/kapalı tercihi hatırlanır.
private struct GlossarySection: View {
    let glossary: [GlossaryEntry]
    @AppStorage(SettingsKey.glossaryExpanded) private var isExpanded: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.smooth(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("SÖZLÜK")
                        .appFont(size: 11, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(Theme.muted)
                    Text("\(glossary.count) terim")
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Theme.soft, in: Capsule())
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .appFont(size: 11, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .hoverHint(isExpanded ? "Sözlüğü kapat" : "Sözlüğü aç", alignment: .trailing, edge: .bottom)
            .accessibilityValue(isExpanded ? Text("Sözlük açık") : Text("Sözlük kapalı"))
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(glossary.enumerated()), id: \.offset) { (item: (offset: Int, element: GlossaryEntry)) in
                        if item.offset > 0 {
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                        // Genişte yan yana, dar panelde alt alta.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                term(entry: item.element).frame(width: 200, alignment: .leading)
                                meaning(entry: item.element).frame(minWidth: 240, idealWidth: 240, maxWidth: .infinity, alignment: .leading)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                term(entry: item.element)
                                meaning(entry: item.element)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .cardSurface(cornerRadius: 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Kapalıyken ilk terimler; tıklayınca açılır.
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(glossary.prefix(6), id: \.term) { (entry: GlossaryEntry) in
                        Text(entry.term)
                            .appFont(size: 12, weight: .medium)
                            .foregroundStyle(Theme.ink.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Theme.soft, in: Capsule())
                    }
                    if glossary.count > 6 {
                        Text(verbatim: "+\(glossary.count - 6)")
                            .appFont(size: 12, weight: .medium)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(Theme.line))
                    }
                }
                .onTapGesture { withAnimation(.smooth(duration: 0.3)) { isExpanded = true } }
                .pointerStyle(.link)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func term(entry: GlossaryEntry) -> some View {
        Text(entry.term)
            .font(appearance.font(size: appearance.textSize, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func meaning(entry: GlossaryEntry) -> some View {
        Text(entry.meaning)
            .font(appearance.font(size: appearance.textSize, weight: .regular))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Notun paylaşım dilindeki sürümü: yoksa hazırlanır (ilerleme, hata ve yeniden dene); varsa özet, kararlar ve
/// sahipli görevler; üstte kopyala ve paylaş.
private struct SharedNoteSection: View {
    let model: AppModel
    let record: MeetingRecord
    let note: MeetingNote
    let language: ShareLanguage
    @State private var error: String?
    @State private var attempt: Int = 0
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Group {
            if let shared = record.sharedNotes?[language.rawValue] {
                content(shared: shared)
            } else if let error {
                VStack(alignment: .leading, spacing: 8) {
                    EmptyStateCard(symbol: "exclamationmark.triangle", title: "Çeviri yapılamadı", message: LocalizedStringKey(error))
                    Button("Yeniden dene", systemImage: "arrow.clockwise") {
                        self.error = nil
                        attempt += 1
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(language == .finnish ? "Suomenkielinen versio valmistuu…" : "Preparing the English version…")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 8)
            }
        }
        // Not yeniden yazılınca ya da kilit kalkınca yeniden denenir (aksi halde bekleme göstergesi takılı kalırdı).
        .task(id: "\(language.rawValue)-\(attempt)-\(record.sharedNotes?[language.rawValue] == nil)-\(note.summary.hashValue)-\(model.isLocked(meetingID: record.id))") {
            guard record.sharedNotes?[language.rawValue] == nil, error == nil else {
                return
            }
            error = await model.generateSharedNote(meetingID: record.id, language: language)
        }
    }

    private func content(shared: MeetingNote) -> some View {
        let text: String = shareText(record: record, note: shared, language: language)
        let headings: (summary: String, decisions: String, tasks: String) = language == .finnish
            ? ("YHTEENVETO", "PÄÄTÖKSET", "TEHTÄVÄT")
            : ("SUMMARY", "DECISIONS", "ACTION ITEMS")
        return VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                Text(shared.title)
                    .appFont(size: 20, weight: .medium)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Kopyala", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                ShareLink(item: text, subject: Text(shared.title)) {
                    Label("Paylaş", systemImage: "square.and.arrow.up")
                }
            }
            sharedSection(title: headings.summary) {
                Text(shared.summary)
                    .font(appearance.font(size: appearance.textSize + 2, weight: .regular))
                    .lineSpacing(appearance.lineSpacing + 2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !shared.decisions.isEmpty {
                sharedSection(title: headings.decisions) {
                    ForEach(Array(shared.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                        Text("\(item.offset + 1). \(item.element)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !shared.tasks.isEmpty {
                sharedSection(title: headings.tasks) {
                    ForEach(Array(shared.tasks.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                        let owner: Text = Text(item.element.owner).fontWeight(.semibold)
                        let due: Text = Text(item.element.dueDate.map { " (\($0))" } ?? "").foregroundStyle(Theme.muted)
                        Text("\(owner) — \(item.element.description)\(due)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(appearance.bodyFont)
        .padding(20)
        .frame(maxWidth: 760, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }

    private func sharedSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
            content()
        }
    }
}

/// Konu akışında bir bölüm: solda zaman (ses varsa tıklayınca oradan çalar) ve dikey çizgi, sağda başlık ve özet.
private struct OutlineRow: View {
    let item: OutlineItem
    let isLast: Bool
    let canPlay: Bool
    let onPlay: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Button(action: onPlay) {
                    HStack(spacing: 4) {
                        if canPlay {
                            Image(systemName: "play.fill").appFont(size: 8, weight: .bold)
                        }
                        Text(timestamp(seconds: item.startSec)).appFont(size: 12, weight: .medium).monospacedDigit()
                    }
                    .foregroundStyle(canPlay ? appearance.accent.color : Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.soft, in: Capsule())
                }
                .buttonStyle(.hoverCapsule)
                .disabled(!canPlay)
                .hoverHint("Buradan dinle", alignment: .leading, edge: .bottom)
                if !isLast {
                    Rectangle().fill(Theme.line).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(appearance.font(size: appearance.textSize, weight: .semibold))
                Text(item.summary)
                    .font(appearance.secondaryFont)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            .padding(.bottom, isLast ? 0 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "01", "02": karar numarası. Saf fonksiyondur.
private func decisionNumber(index: Int) -> String {
    index + 1 < 10 ? "0\(index + 1)" : "\(index + 1)"
}

/// Görev kartı: sahibinin harf rozeti, sahibi ve iş, varsa tarih çipi.
private struct TaskCard: View {
    let model: AppModel
    let record: MeetingRecord
    let task: NoteTask

    var body: some View {
        let isDone: Bool = isTaskDone(record: record, task: task)
        HStack(alignment: .top, spacing: 12) {
            TaskCheckbox(isDone: isDone) { model.toggleTask(meetingID: record.id, task: task) }
                .disabled(model.isLocked(meetingID: record.id))
            SpeakerAvatar(text: ownerInitial(owner: task.owner), color: ownerColor(task: task, speakerNames: record.speakerNames), size: 26)
            VStack(alignment: .leading, spacing: 6) {
                let owner: Text = Text(task.owner).fontWeight(.semibold)
                Text("\(owner) — \(task.description)")
                    .strikethrough(isDone, color: Theme.muted)
                    .foregroundStyle(isDone ? Theme.muted : Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let due = task.dueDate {
                    Label(due, systemImage: "calendar")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Theme.soft, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ReminderButton(model: model, record: record, task: task)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardSurface(cornerRadius: 14)
        .animation(.smooth(duration: 0.2), value: isDone)
    }
}

/// Görevin tamamlandı kutusu: boş daire / dolu onay; el imleci, basınca küçülür.
struct TaskCheckbox: View {
    let isDone: Bool
    let onToggle: @MainActor () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(isDone ? Color.green : Theme.muted)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.hoverPlain)
        .hoverHint(isDone ? "Yapılmadı olarak işaretle" : "Yapıldı olarak işaretle", alignment: .leading, edge: .bottom)
        .accessibilityLabel(isDone ? Text("Yapıldı") : Text("Yapılmadı"))
    }
}

/// Görevi Apple Anımsatıcılar'a ekleyen zil düğmesi; eklendiyse dolu zil (yeniden eklenmez), hata altında görünür.
struct ReminderButton: View {
    let model: AppModel
    let record: MeetingRecord
    let task: NoteTask
    @State private var isAdding: Bool = false
    @State private var error: String?

    var body: some View {
        let reminded: Bool = isTaskReminded(record: record, task: task)
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                isAdding = true
                Task {
                    error = await model.addToReminders(meetingID: record.id, task: task)
                    isAdding = false
                }
            } label: {
                Group {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: reminded ? "bell.badge.fill" : "bell")
                            .foregroundStyle(reminded ? Color.orange : Theme.muted)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.hoverPlain)
            // İşlenirken eklenen anımsatıcı işaretlenemezdi; tekrar eklenmesin diye kapalı.
            .disabled(reminded || isAdding || model.isLocked(meetingID: record.id))
            .hoverHint(reminded ? "Anımsatıcılar'da" : "Anımsatıcılar'a ekle", alignment: .trailing, edge: .bottom)
            if let error {
                Text(error)
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Görev sahibinin rozet harfi: "Konuşmacı 2" → "2", "Aino" → "A". Saf fonksiyondur.
private func ownerInitial(owner: String) -> String {
    if let number = speakerNumber(owner: owner) {
        return "\(number)"
    }
    return owner.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
}

/// Not "Konuşmacı N" yazdıysa N (not her zaman Türkçe yazılır). Saf fonksiyondur.
private func speakerNumber(owner: String) -> Int? {
    let prefix: String = "Konuşmacı "
    return owner.hasPrefix(prefix) ? Int(owner.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)) : nil
}

/// Görev sahibinin rengi: sen mavi, adı verilmiş ya da numaralı konuşmacı kendi rengi, diğerleri addan sabit bir renk.
/// Saf fonksiyondur.
private func ownerColor(task: NoteTask, speakerNames: [Int: String]) -> Color {
    if task.isMine {
        return DesignTokens.meColor
    }
    if let person = speakerNumber(owner: task.owner)
        ?? speakerNames.first(where: { $0.value.caseInsensitiveCompare(task.owner) == .orderedSame })?.key {
        return personColor(person: person)
    }
    let hash: Int = task.owner.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    return personColor(person: hash % DesignTokens.personPalette.count + 1)
}

/// Konuşmacının rengi: numaralı kişi kendi rengi, "Sen" mavi, ayrılmamış "Diğerleri" gri. Saf fonksiyondur.
private func speakerColor(key: SpeakerKey) -> Color {
    switch (key.speaker, key.person) {
    case (_, .some(let person)): personColor(person: person)
    case (.me, nil): DesignTokens.meColor
    case (.others, nil): Color.gray
    }
}

/// Konuşmacının görünen adı: verilen ad, yoksa "Konuşmacı N", "Sen" ya da "Diğerleri". Saf fonksiyondur.
private func speakerName(key: SpeakerKey, speakerNames: [Int: String]) -> String {
    if let person = key.person, let name = speakerNames[person], !name.isEmpty {
        return name
    }
    return speakerLabel(speaker: key.speaker, person: key.person)
}

/// Rozet harfi: adın baş harfi, adsız numaralı kişide numara, "Sen"/"Diğerleri"nde etiketin baş harfi. Saf fonksiyondur.
private func avatarText(key: SpeakerKey, speakerNames: [Int: String]) -> String {
    if let person = key.person, speakerNames[person]?.isEmpty ?? true {
        return "\(person)"
    }
    return speakerName(key: key, speakerNames: speakerNames).first.map { String($0).uppercased() } ?? "?"
}

/// Renkli daire içinde beyaz harf (konuşmacı ve görev sahibi rozeti).
private struct SpeakerAvatar: View {
    let text: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Text(text)
            .appFont(size: size * 0.44, weight: .semibold)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
    }
}

/// Kapaktaki konuşmacı zaman çizgisi: kim ne zaman konuştu; çalarken beyaz okuma çizgisi; tıklayınca oradan çalar.
private struct SpeakerTimeline: View {
    let spans: [SpeakerSpan]
    let totalSec: Double
    let player: MeetingAudioPlayer
    let meetingID: String
    let canPlay: Bool
    let onSeek: @MainActor (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { (proxy: GeometryProxy) in
                let width: CGFloat = proxy.size.width
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.28))
                        ForEach(Array(spans.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerSpan)) in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(speakerColor(key: item.element.key))
                                .frame(width: max(2, width * (item.element.endSec - item.element.startSec) / totalSec))
                                .offset(x: width * item.element.startSec / totalSec)
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                    if player.meetingID == meetingID {
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 3, height: 14)
                            .shadow(color: .black.opacity(0.35), radius: 2)
                            .offset(x: width * min(1, max(0, player.currentTime / totalSec)) - 1.5)
                    }
                }
                .frame(width: width, height: 14)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { (location: CGPoint) -> Void in
                    if canPlay {
                        onSeek(totalSec * min(1, max(0, location.x / width)))
                    }
                }
                .pointerStyle(canPlay ? .link : nil)
            }
            .frame(height: 14)
            HStack(spacing: DesignTokens.Spacing.s) {
                Text(verbatim: "00:00")
                Spacer(minLength: 0)
                Text(canPlay ? "Kim ne zaman konuştu · tıkla, oradan çal" : "Kim ne zaman konuştu")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(timestamp(seconds: totalSec))
            }
            .appFont(size: 11, weight: .regular)
            .monospacedDigit()
            .opacity(0.75)
        }
    }
}

/// Konuşmacılar transkriptin başında çip olarak: tıklayınca ad verme ya da başka konuşmacıyla birleştirme (ayırma aynı
/// kişiyi ikiye böldüyse); yanında akıllı modelin ad/birleştirme önerileri ("Gözden geçir").
private struct SpeakerChips: View {
    let model: AppModel
    let record: MeetingRecord
    let isLocked: Bool
    let onPlay: @MainActor (Double) -> Void

    var body: some View {
        // Gösterilen transkriptle aynı bölüm kümesi.
        let persons: [Int] = Array(Set(meetingSegments(record: record).compactMap(\.person))).sorted()
        if !persons.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.s) {
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(persons, id: \.self) { (person: Int) in
                            SpeakerChip(model: model, record: record, person: person, others: persons.filter { $0 != person })
                                .disabled(isLocked)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            }
        }
    }
}

/// Konuşmacı çipi: rozet ve ad; tıklayınca menü (ad ver, birleştir). Ad verirken çip yazı alanına döner: Enter kaydeder,
/// Esc vazgeçer, odaktan çıkınca kaydedilir.
private struct SpeakerChip: View {
    let model: AppModel
    let record: MeetingRecord
    let person: Int
    let others: [Int]
    @State private var isEditing: Bool = false
    @State private var name: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let key: SpeakerKey = SpeakerKey(speaker: .others, person: person)
        let current: String = record.speakerNames[person] ?? ""
        Group {
            if isEditing {
                HStack(spacing: 8) {
                    SpeakerAvatar(text: avatarText(key: key, speakerNames: record.speakerNames), color: speakerColor(key: key), size: 24)
                    TextField("Ad (ör. Aino)", text: $name)
                        .textFieldStyle(.plain)
                        .appFont(size: 13, weight: .medium)
                        .frame(width: 140)
                        .focused($isFocused)
                        .onSubmit { commit() }
                        .onExitCommand { isEditing = false }
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.ink))
                .onAppear { isFocused = true }
                .onChange(of: isFocused) { (_: Bool, focused: Bool) in
                    if !focused, isEditing {
                        commit()
                    }
                }
            } else {
                Menu {
                    Button(current.isEmpty ? "Ad ver…" : "Adı değiştir…", systemImage: "pencil") {
                        name = current
                        isEditing = true
                    }
                    if !others.isEmpty {
                        Menu("Şununla birleştir") {
                            ForEach(others, id: \.self) { (target: Int) in
                                Button(speakerName(key: SpeakerKey(speaker: .others, person: target), speakerNames: record.speakerNames)) {
                                    model.mergeSpeakers(meetingID: record.id, from: person, into: target)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        SpeakerAvatar(text: avatarText(key: key, speakerNames: record.speakerNames), color: speakerColor(key: key), size: 24)
                        Text(speakerName(key: key, speakerNames: record.speakerNames))
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(Theme.ink)
                        Image(systemName: "chevron.down")
                            .appFont(size: 9, weight: .semibold)
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                }
                .menuStyle(.button)
                .buttonStyle(.hoverCapsule)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHint("Ad ver ya da başka konuşmacıyla birleştir", alignment: .leading, edge: .bottom)
            }
        }
        .animation(.smooth(duration: 0.2), value: isEditing)
    }

    private func commit() {
        isEditing = false
        model.renameSpeaker(meetingID: record.id, person: person, name: name)
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
                Label("Öneri yok: transkriptte ad ya da birleştirme için yeterli ipucu bulunamadı.", systemImage: "lightbulb")
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

/// Ses varsa konuşma satırı tıklanabilir: hover'da soluk zemin ve sağ üstte çal düğmesi, el imleci; yoksa düz metin
/// (tıklanabilir görünmesin).
private struct PlayableTurn: ViewModifier {
    let canPlay: Bool
    let onTap: @MainActor () -> Void
    @State private var isHovering: Bool = false

    func body(content: Content) -> some View {
        if canPlay {
            content
                .background(isHovering ? Theme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isHovering {
                        Image(systemName: "play.fill")
                            .appFont(size: 10, weight: .semibold)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 28, height: 28)
                            .background(Theme.primary, in: Circle())
                            .padding(10)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { onTap() }
                .onHover { (hovering: Bool) -> Void in isHovering = hovering }
                .pointerStyle(.link)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Buradan dinle")
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
    /// İşaret eklenip kaldırılabilir (kayıtta/işlemede değil).
    let canEdit: Bool
    let onToggleHighlight: @MainActor (TranscriptParagraph) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let isActivePlayer: Bool = player.meetingID == record.id
        let highlights: [Highlight] = record.highlights ?? []
        let time: Double = player.currentTime
        LazyVStack(alignment: .leading, spacing: 2) {
            if let error = player.errorMessage {
                Text(error).appFont(size: 11, weight: .regular).foregroundStyle(.red)
            }
            ForEach(Array(paragraphs.enumerated()), id: \.element.id) { (item: (offset: Int, element: TranscriptParagraph)) in
                let paragraph: TranscriptParagraph = item.element
                let key: SpeakerKey = SpeakerKey(speaker: paragraph.speaker, person: paragraph.person)
                // Aynı konuşmacı sürüyorsa rozet ve ad tekrar edilmez (sohbet gibi).
                let continues: Bool = item.offset > 0
                    && SpeakerKey(speaker: paragraphs[item.offset - 1].speaker, person: paragraphs[item.offset - 1].person) == key
                let isActive: Bool = isActivePlayer && time >= paragraph.startSec && time < paragraph.endSec + 0.4
                HStack(alignment: .top, spacing: 12) {
                    if continues {
                        Color.clear.frame(width: 32, height: 1)
                    } else {
                        SpeakerAvatar(text: avatarText(key: key, speakerNames: record.speakerNames), color: speakerColor(key: key), size: 32)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !continues {
                                Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames))
                                    .appFont(size: 13, weight: .semibold)
                            }
                            Text(timestamp(seconds: paragraph.startSec))
                                .appFont(size: 12, weight: .regular)
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                            let marked: Bool = isHighlighted(paragraph: paragraph, highlights: highlights)
                            Button {
                                onToggleHighlight(paragraph)
                            } label: {
                                Image(systemName: marked ? "bookmark.fill" : "bookmark")
                                    .appFont(size: 11, weight: .medium)
                                    .foregroundStyle(marked ? appearance.accent.color : Theme.muted.opacity(0.6))
                            }
                            .buttonStyle(.hoverPlain)
                            .disabled(!canEdit)
                            .hoverHint(marked ? "İşareti kaldır" : "Önemli olarak işaretle (notta öne çıkar)", alignment: .leading, edge: .bottom)
                        }
                        paragraphText(paragraph: paragraph, isActive: isActive, time: time)
                            .font(appearance.bodyFont)
                            .lineSpacing(appearance.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                        if let turkish = paragraph.turkish {
                            Text(turkish)
                                .font(appearance.secondaryFont)
                                .lineSpacing(appearance.lineSpacing)
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
                                .padding(.top, 2)
                        }
                    }
                    // Çal düğmesi metnin üstüne binmesin.
                    .padding(.trailing, canPlay ? 30 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, continues ? 6 : 12)
                .padding(.horizontal, 10)
                .background(isActive ? appearance.accent.color.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .modifier(PlayableTurn(canPlay: canPlay) { onPlay(paragraph.startSec) })
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
}

/// Çalan toplantının oynatıcısı (ana pencerenin ve panelin altında): sayfa değişse de ses sürer ve oynatıcı görünür.
/// Toplantı silinir ya da sesi silinirse (saklama süresi) çalma durur.
struct PlayerDock: View {
    let model: AppModel
    let player: MeetingAudioPlayer
    /// Toplantı başlığına tıklanınca o toplantıyı açar.
    let onOpen: @MainActor (String) -> Void

    var body: some View {
        // Bu gövde yalnızca çalan toplantı değişince yeniden hesaplanır; konum güncellemeleri çubuğun içinde kalır.
        let record: MeetingRecord? = player.meetingID.flatMap { (id: String) -> MeetingRecord? in model.meetings.first { $0.id == id } }
        Group {
            if let record, !record.audioDeleted {
                NowPlayingBar(
                    player: player, paragraphs: transcriptParagraphs(record: record), speakerNames: record.speakerNames,
                    title: record.note?.title ?? record.title, onOpen: { onOpen(record.id) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: record?.id)
        .onChange(of: player.meetingID.map { (id: String) -> Bool in record?.audioDeleted ?? true }) { (_: Bool?, gone: Bool?) in
            if gone == true {
                player.stop()
            }
        }
    }
}

/// Spotify tarzı çalma çubuğu: toplantı başlığı (tıklayınca açılır), çalan konuşmacı ve sözü, konum çubuğu ve
/// süreler, 10 sn geri / oynat-duraklat / 10 sn ileri, hız ve kapat.
private struct NowPlayingBar: View {
    let player: MeetingAudioPlayer
    let paragraphs: [TranscriptParagraph]
    let speakerNames: [Int: String]
    let title: String
    let onOpen: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let time: Double = player.currentTime
        let current: TranscriptParagraph? = paragraphs.last { $0.startSec <= time }
        VStack(spacing: 8) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            .foregroundStyle(appearance.accent.color)
                        Text(title)
                            .appFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("Toplantıyı aç", alignment: .leading, edge: .top)
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
            HStack(spacing: DesignTokens.Spacing.s) {
                if let current {
                    Circle()
                        .fill(speakerColor(key: SpeakerKey(speaker: current.speaker, person: current.person)))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(paragraphLabel(paragraph: current, speakerNames: speakerNames))
                            .appFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                        Text(current.turkish ?? current.text)
                            .appFont(size: 12, weight: .regular)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
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

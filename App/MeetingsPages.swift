import AINotepadCore
import AINotepadUI
import AppKit
import os
import SwiftUI

private let meetingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Meetings")

// MARK: Liste

/// Toplantı listesi (ana pencerenin Toplantılar bölümünde solda): arama, süzgeç ve tarihe göre gruplu (Bugün, Dün,
/// Bu hafta, aylar) yeniden eskiye liste.
struct MeetingsListPage: View {
    let model: AppModel
    /// Açık toplantı (satırı vurgulanır).
    let selectedID: String?
    /// Üst çubuktaki arama.
    let query: String
    /// Kenar çubuğunda seçilen klasör; nil hepsi.
    let folder: String?
    let onClearFolder: @MainActor () -> Void
    let onOpen: @MainActor (String) -> Void
    /// Toplu silmeden sonra (açık toplantı silindiyse sayfa kapanır).
    let onDeleted: @MainActor (Set<String>) -> Void
    /// "Seç" modu: satırlara tıklamak toplantıyı açmaz, işaretler.
    @State private var isSelecting: Bool = false
    @State private var checked: Set<String> = []
    @State private var isConfirmingDelete: Bool = false
    @State private var deleteErrors: [String] = []
    @State private var listFilter: MeetingListFilter = .all

    var body: some View {
        let visible: [MeetingRecord] = filterMeetings(
            records: filterMeetings(records: meetingsInFolder(records: model.meetings, folder: folder), query: query),
            listFilter: listFilter
        )
        let sections: [MeetingSection] = meetingSections(records: visible, now: Date(), calendar: .current, locale: interfaceLocale())
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.s) {
                if let folder {
                    Button {
                        onClearFolder()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                            Text(folder).lineLimit(1)
                            Image(systemName: "xmark").appFont(size: 9, weight: .bold)
                        }
                        .appFont(size: 12, weight: .medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.soft, in: Capsule())
                    }
                    .buttonStyle(.hoverCapsule)
                    .hoverHint("Tüm toplantılar", alignment: .leading, edge: .bottom)
                }
                Text(query.isEmpty ? String(localized: "\(visible.count) toplantı") : String(localized: "\(visible.count) sonuç"))
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
            if !model.meetings.isEmpty {
                PillPicker(selection: $listFilter, options: [
                    (MeetingListFilter.all, "Hepsi"), (MeetingListFilter.myTasks, "Görevim olanlar"), (MeetingListFilter.problems, "Hatalı"),
                ])
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.bottom, DesignTokens.Spacing.s)
            }
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
                if listFilter == .all {
                    EmptyStatePlaceholder(symbol: "magnifyingglass", title: "Eşleşen toplantı yok", message: "Başlıkta, notta ya da metinde başka bir kelimeyle ara.")
                } else {
                    EmptyStatePlaceholder(symbol: "line.3.horizontal.decrease", title: "Eşleşen toplantı yok", message: "Süzgeci \"Hepsi\" yap ya da başka bir kelimeyle ara.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { (section: MeetingSection) in
                            Text(interfaceUppercased(text: section.title))
                                .appFont(size: 11, weight: .semibold)
                                .tracking(DesignTokens.labelTracking)
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, DesignTokens.Spacing.m)
                                .padding(.top, section.id == sections.first?.id ? DesignTokens.Spacing.xs : DesignTokens.Spacing.m)
                                .padding(.bottom, DesignTokens.Spacing.xs)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.meetings) { (record: MeetingRecord) in
                                row(record: record)
                                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                            }
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
            .contextMenu {
                Button("Aç", systemImage: "arrow.up.right") { onOpen(record.id) }
                Button("Markdown olarak kopyala", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meetingMarkdown(record: record), forType: .string)
                }
                Divider()
                // Çöp Sepeti'ne taşır: Finder'dan geri alınabilir.
                Button("Çöp Sepeti'ne taşı", systemImage: "trash", role: .destructive) {
                    if let error = model.deleteMeeting(meetingID: record.id) {
                        deleteErrors = [error]
                    }
                }
                .disabled(model.isLocked(meetingID: record.id))
            }
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
                    Menu {
                        ForEach(model.folders) { (item: FolderSummary) in
                            Button(item.name, systemImage: "folder") { model.moveMeetings(ids: checked, to: item.name) }
                        }
                        Divider()
                        Button("Klasörden çıkar", systemImage: "folder.badge.minus") { model.moveMeetings(ids: checked, to: nil) }
                    } label: {
                        Label("Klasöre taşı", systemImage: "folder")
                    }
                    .fixedSize()
                    .disabled(checked.isEmpty)
                    Button("Sil", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                        .disabled(checked.isEmpty)
                }
            }
        }
        .controlSize(.small)
        .padding(DesignTokens.Spacing.m)
        .pageBackground()
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

/// Liste satırı: başlık, tarih, süre, durum ve varsa senin görev sayın.
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
                    if let minutes = meetingDurationMinutes(record: record) {
                        Text("· " + String(localized: "\(minutes) dk"))
                    }
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
    /// Başka bir hedefe gönderildi (Apple Notlar, klasör): kısa onay metni.
    case done(String)
    case failed(String)
    /// "Toplantıyı sil"e basıldı: satır içi onay bekleniyor (ayrı uyarı penceresi yok).
    case confirmDelete
    /// "Sesi sil"e basıldı: ses kalıcı silinir, satır içi onay bekleniyor.
    case confirmDeleteAudio
}

/// Seçili toplantının sayfası: önce sana düşen görevler, sonra özet, kararlar, diğer görevler, sözlük,
/// konuşmacı adları ve paragraflı transkript (zaman damgasından çalma).
struct MeetingDetailPage: View {
    let model: AppModel
    let player: MeetingAudioPlayer
    let record: MeetingRecord
    /// Toplantı silinince (sayfa artık gösterilemez) çağrılır.
    let onDeleted: @MainActor () -> Void
    /// Tarifi bu toplantıya uygular (Sor sayfasında açılır).
    let onRunRecipe: @MainActor (Recipe) -> Void
    @State private var export: ExportStatus = .none
    @State private var tab: MeetingTab = .summary
    /// Özetin gösterildiği dil: nil Türkçe not, değilse paylaşım sürümü.
    @State private var noteLanguage: ShareLanguage?
    /// Başlık düzenleniyor (çift tıklama ya da "Yeniden adlandır").
    @State private var isRenaming: Bool = false
    @State private var draftTitle: String = ""
    @FocusState private var titleFocused: Bool

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
                            HStack(spacing: 8) {
                                // Fince ve İngilizce hep görünür; seçilen diğer dil de dördüncü olarak eklenir.
                                let others: [(value: ShareLanguage?, title: LocalizedStringKey)] = noteLanguage.flatMap { (language: ShareLanguage) -> [(value: ShareLanguage?, title: LocalizedStringKey)]? in
                                    [.finnish, .english].contains(language) ? nil : [(value: language, title: LocalizedStringKey(language.nativeName))]
                                } ?? []
                                PillPicker(selection: $noteLanguage, options: [
                                    (value: nil, title: "Türkçe"), (value: ShareLanguage.finnish, title: "Suomi"), (value: ShareLanguage.english, title: "English"),
                                ] + others)
                                .fixedSize()
                                .hoverHint("İş arkadaşlarına göndermek için notun başka dildeki sürümü", alignment: .leading, edge: .bottom)
                                Menu {
                                    ForEach(ShareLanguage.allCases.filter { ![.finnish, .english].contains($0) }, id: \.self) { (language: ShareLanguage) in
                                        Button(language.nativeName) { noteLanguage = language }
                                    }
                                } label: {
                                    Label("Diğer diller", systemImage: "globe")
                                }
                                .menuStyle(.button)
                                .buttonStyle(.pill)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .hoverHint("Notu 30'dan fazla dilden birine çevir", alignment: .leading, edge: .bottom)
                            }
                            if let language = noteLanguage {
                                // Dil değişince durum (hata, deneme) sıfırlansın.
                                SharedNoteSection(model: model, record: record, note: note, language: language)
                                    .id(language)
                            } else {
                                SummaryTab(
                                    model: model, note: note, record: record, paragraphs: paragraphs, canPlay: !playableAudio.isEmpty,
                                    onPlay: { (startSec: Double) -> Void in play(from: startSec) },
                                    onClip: { (paragraph: TranscriptParagraph) -> Void in exportClip(paragraph: paragraph) }
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
                            onToggleHighlight: { (paragraph: TranscriptParagraph) -> Void in model.toggleHighlight(meetingID: record.id, paragraph: paragraph) },
                            onClip: { (paragraph: TranscriptParagraph) -> Void in exportClip(paragraph: paragraph) }
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
            // "--cal <saniye>": transkripti açıp oradan çalar (kelime vurgusunun akışını görsel kontrol için).
            if let index = CommandLine.arguments.firstIndex(of: "--cal"), CommandLine.arguments.indices.contains(index + 1),
               let startSec = Double(CommandLine.arguments[index + 1]) {
                play(from: startSec)
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
        sendStatus(state: model.webhookStates[record.id], sending: "Kanala gönderiliyor…", sent: "Not kanala gönderildi")
        sendStatus(state: model.trackerStates[record.id], sending: "Görevler açılıyor…", sent: "Görevler gönderildi")
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
            // Kapak şeridi: toplantının gradyanı (yazı altta, beyaz zeminde).
            CoverImage(seed: record.id)
                .frame(height: 132)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 22, style: .continuous))
                .padding(EdgeInsets(top: -24, leading: -26, bottom: 18, trailing: -26))
            Text(record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(interfaceLocale())))
                .appFont(size: 12, weight: .medium)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
            Group {
                if isRenaming {
                    TextField("Toplantı adı", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .onSubmit { finishRename() }
                        .onExitCommand { isRenaming = false }
                        .onChange(of: titleFocused) { (_: Bool, focused: Bool) in
                            if !focused {
                                finishRename()
                            }
                        }
                } else {
                    Text(record.note?.title ?? record.title)
                        .lineLimit(3)
                        .onTapGesture(count: 2) { startRename() }
                        .hoverHint("Yeniden adlandırmak için çift tıkla", alignment: .leading, edge: .bottom)
                }
            }
            .appFont(size: 28, weight: .semibold)
            .tracking(-0.7)
            .padding(.top, 6)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                // Konuşanlar: üst üste binen rozetler (en çok konuşan önde), fazlası sayıyla.
                let speakers: [SpeakerShare] = speakerShares(paragraphs: paragraphs)
                if !speakers.isEmpty {
                    HStack(spacing: -7) {
                        ForEach(Array(speakers.prefix(4).enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerShare)) in
                            SpeakerAvatar(text: avatarText(key: item.element.key, speakerNames: record.speakerNames), color: speakerColor(key: item.element.key), size: 24)
                                .overlay(Circle().strokeBorder(Theme.card, lineWidth: 1.5))
                                .zIndex(Double(4 - item.offset))
                        }
                    }
                    .padding(.trailing, 4)
                    .hoverHint(LocalizedStringKey(speakers.prefix(6).map { speakerName(key: $0.key, speakerNames: record.speakerNames) }.joined(separator: ", ")), alignment: .leading, edge: .bottom)
                }
                ForEach(heroChips(paragraphs: paragraphs), id: \.self) { (chip: String) in
                    Text(chip)
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.soft, in: Capsule())
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
        .foregroundStyle(Theme.ink)
        .padding(EdgeInsets(top: 24, leading: 26, bottom: 18, trailing: 26))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Yalnızca zemin kırpılır: düğme ipuçları kartın dışına taşabilsin.
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line))
        }
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
                    .buttonStyle(.pill)
                    .disabled(isLocked)
                    .hoverHint("Notu adlarla yeniden yaz", alignment: .leading, edge: .bottom)
                Menu {
                    ForEach(model.recipes) { (recipe: Recipe) in
                        Button(recipe.title, systemImage: recipe.symbol) { onRunRecipe(recipe) }
                    }
                } label: {
                    Label("Tarif", systemImage: "wand.and.stars")
                }
                .menuStyle(.button)
                .buttonStyle(.pill)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(record.note == nil)
                .hoverHint("Bu toplantıya tarif uygula: takip e-postası, aksiyonlar, proje planı…", alignment: .leading, edge: .bottom)
                Spacer(minLength: DesignTokens.Spacing.s)
                if let text = displayedShareText {
                    ShareLink(item: text, subject: Text(record.note?.title ?? record.title)) {
                        Label("Paylaş", systemImage: "square.and.arrow.up")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.pill)
                    .hoverHint("Notu paylaş (Mail, Mesajlar, Notlar…); seçili dilde", alignment: .trailing, edge: .bottom)
                }
                Button("PDF", systemImage: "doc.richtext") { exportPDF() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.pill)
                    .hoverHint("PDF olarak İndirilenler'e kaydet", alignment: .trailing, edge: .bottom)
                Button("Markdown", systemImage: "square.and.arrow.down") { exportMarkdown() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.pill)
                    .hoverHint("Markdown olarak kaydet", alignment: .trailing, edge: .bottom)
                Button("Kopyala", systemImage: "doc.on.doc") { copyMarkdown() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.pill)
                    .hoverHint("Markdown olarak kopyala", alignment: .trailing, edge: .bottom)
                moreMenu {
                    fileExportItems
                    Divider()
                    webhookItem
                    Divider()
                    manageItems
                }
            }
            HStack(spacing: DesignTokens.Spacing.s) {
                listenButton
                Spacer(minLength: DesignTokens.Spacing.s)
                moreMenu {
                    exportItems
                    Divider()
                    fileExportItems
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
            .buttonStyle(.pillPrimary)
            .hoverHint("Baştan dinle; çalan kelime renklenir", alignment: .leading, edge: .bottom)
        }
    }

    /// "⋯" menüsü: başlık kartında hap.
    private func moreMenu(@ViewBuilder items: () -> some View) -> some View {
        Menu {
            items()
        } label: {
            // Simge düğmeleriyle aynı genişlikte daire.
            Image(systemName: "ellipsis").frame(width: 16, height: 16)
        }
        .menuStyle(.button)
        .buttonStyle(.pill)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHint("Diğer işlemler", alignment: .trailing, edge: .bottom)
    }

    /// Dar panelde menüye taşınan not ve dışa aktarma eylemleri.
    @ViewBuilder
    private var exportItems: some View {
        Button("Notu yenile", systemImage: "sparkles") { model.regenerateNote(meetingID: record.id) }
            .disabled(isLocked)
        Menu("Tarif uygula", systemImage: "wand.and.stars") {
            ForEach(model.recipes) { (recipe: Recipe) in
                Button(recipe.title, systemImage: recipe.symbol) { onRunRecipe(recipe) }
            }
        }
        .disabled(record.note == nil)
        Button("PDF olarak kaydet", systemImage: "doc.richtext") { exportPDF() }
        Button("Markdown olarak kaydet", systemImage: "square.and.arrow.down") { exportMarkdown() }
        Button("Markdown olarak kopyala", systemImage: "doc.on.doc") { copyMarkdown() }
        Button("E-postayla gönder", systemImage: "envelope") { emailNote() }
            .disabled(record.note == nil)
        webhookItem
    }

    /// Dosya olarak dışa aktarma: Word belgesi (seçili not dilinde), transkriptin düz metni ve SRT altyazısı.
    @ViewBuilder
    private var fileExportItems: some View {
        let hasTranscript: Bool = !(record.finalSegments.isEmpty && record.liveSegments.isEmpty)
        Button("Word (DOCX) olarak kaydet", systemImage: "doc.text") { exportDOCX() }
        Button("Transkripti metin olarak kaydet (TXT)", systemImage: "text.alignleft") { exportTranscriptText() }
            .disabled(!hasTranscript)
        Button("Altyazı olarak kaydet (SRT)", systemImage: "captions.bubble") { exportSRT() }
            .disabled(!hasTranscript)
    }

    /// Notu ayarlardaki webhook'a gönderir (Slack, Teams, Discord, Zapier…) ya da paylaşılabilir web sayfası olarak kaydeder.
    @ViewBuilder
    private var webhookItem: some View {
        Button("Web sayfası olarak kaydet", systemImage: "globe") { exportHTML() }
            .disabled(record.note == nil)
        // Bağlı her hedefe ayrı ayrı ya da hepsine; gönderilmiş hedef işaretli.
        Menu("Kanala gönder", systemImage: "paperplane") {
            if model.destinations.isEmpty {
                Text("Ayarlar › Bağlantılar'dan kanal ekle")
            } else {
                ForEach(model.destinations) { (destination: NoteDestination) in
                    let sent: Bool = (record.sentDestinationIDs ?? []).contains(destination.id)
                    Button {
                        Task { await model.sendNote(meetingID: record.id, destinationIDs: [destination.id]) }
                    } label: {
                        Label(
                            "\(destinationName(destination: destination)) · \(destinationDetail(destination: destination))",
                            systemImage: sent ? "checkmark" : "paperplane"
                        )
                    }
                }
                if model.destinations.count > 1 {
                    Divider()
                    Button("Hepsine gönder") {
                        Task { await model.sendNote(meetingID: record.id, destinationIDs: model.destinations.map(\.id)) }
                    }
                }
            }
        }
        .disabled(record.note == nil || model.webhookStates[record.id] == .sending)
        // Görevleri Linear ya da Jira'da iş olarak açar.
        Menu("Görevleri gönder", systemImage: "checklist") {
            if model.taskTrackers.isEmpty {
                Text("Ayarlar › Bağlantılar › Görev araçları'ndan Linear ya da Jira bağla")
            } else {
                ForEach(model.taskTrackers) { (tracker: TaskTracker) in
                    Button("Bana düşenleri \(tracker.service.displayName)'e gönder") {
                        Task { await model.sendTasks(meetingID: record.id, trackerID: tracker.id, onlyMine: true) }
                    }
                    Button("Tüm görevleri \(tracker.service.displayName)'e gönder") {
                        Task { await model.sendTasks(meetingID: record.id, trackerID: tracker.id, onlyMine: false) }
                    }
                }
            }
        }
        .disabled((record.note?.tasks ?? []).isEmpty || model.trackerStates[record.id] == .sending)
        Button("Apple Notlar'a gönder", systemImage: "note.text") {
            Task {
                if let error = await model.sendToAppleNotes(meetingID: record.id) {
                    export = .failed(error)
                } else {
                    export = .done(String(localized: "Notlar'daki \"AI-Notepad\" klasörüne yazıldı."))
                }
            }
        }
        .disabled(record.note == nil)
        Button("Klasöre Markdown kaydet", systemImage: "folder") {
            if let error = model.exportToFolder(meetingID: record.id) {
                export = .failed(error)
            } else {
                export = .done(String(localized: "Seçili klasöre Markdown olarak yazıldı."))
            }
        }
        .disabled(record.note == nil)
    }

    /// Yönetim: yeniden işleme ve silme (kilitliyken kapalı); silme satır içinde onay ister.
    @ViewBuilder
    private var manageItems: some View {
        Menu("Klasöre taşı") {
            ForEach(model.folders) { (item: FolderSummary) in
                Button {
                    model.moveMeetings(ids: [record.id], to: item.name)
                } label: {
                    if record.folder?.caseInsensitiveCompare(item.name) == .orderedSame {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
            if model.folders.isEmpty {
                Text("Önce kenar çubuğunda \"+\" ile klasör oluştur")
            }
            if record.folder != nil {
                Divider()
                Button("Klasörden çıkar", systemImage: "folder.badge.minus") { model.moveMeetings(ids: [record.id], to: nil) }
            }
        }
        .disabled(isLocked)
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
        noteVersionItems
        Button("Yeniden adlandır", systemImage: "pencil") { startRename() }
            .disabled(isLocked)
        Button("Tekrar işle", systemImage: "arrow.clockwise") { model.reprocess(meetingID: record.id) }
            .disabled(isLocked || record.audioDeleted)
        Divider()
        Button("Sesi sil", systemImage: "speaker.slash", role: .destructive) {
            export = .confirmDeleteAudio
        }
        .disabled(isLocked || record.audioDeleted)
        Button("Toplantıyı sil", systemImage: "trash", role: .destructive) { export = .confirmDelete }
            .disabled(isLocked)
    }

    /// Gönderim durumu satırı (kanal ya da görev aracı).
    @ViewBuilder
    private func sendStatus(state: WebhookSendState?, sending: LocalizedStringKey, sent: LocalizedStringKey) -> some View {
        switch state {
        case .sending:
            Label(sending, systemImage: "paperplane").appFont(size: 12, weight: .regular).foregroundStyle(.secondary)
        case .sent:
            Label(sent, systemImage: "checkmark.circle").appFont(size: 12, weight: .regular).foregroundStyle(.secondary)
        case .done(let summary):
            Label(summary, systemImage: "checkmark.circle")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").appFont(size: 12, weight: .regular).foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    /// Notun önceki sürümleri: son değişikliği geri al ve sürüm listesi (tarih ve neden); geri yükleme de geri alınabilir.
    @ViewBuilder
    private var noteVersionItems: some View {
        if let versions = record.noteHistory, let latest = versions.first {
            Button("Geri al (\(latest.reason))", systemImage: "arrow.uturn.backward") {
                model.restoreNoteVersion(meetingID: record.id, index: 0)
            }
            .disabled(isLocked)
            Menu("Önceki sürümler", systemImage: "clock.arrow.circlepath") {
                Section("Değişiklikten önceki not") {
                    ForEach(Array(versions.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteVersion)) in
                        Button(noteVersionTitle(version: item.element, locale: interfaceLocale())) {
                            model.restoreNoteVersion(meetingID: record.id, index: item.offset)
                        }
                    }
                }
            }
            .disabled(isLocked)
        }
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

    private func startRename() {
        guard !isLocked else {
            return
        }
        draftTitle = record.note?.title ?? record.title
        isRenaming = true
        titleFocused = true
    }

    private func finishRename() {
        guard isRenaming else {
            return
        }
        isRenaming = false
        if draftTitle != (record.note?.title ?? record.title) {
            model.renameMeeting(meetingID: record.id, title: draftTitle)
        }
    }

    /// Dışa aktarılan kayıt: seçili dilde paylaşım notu varsa not onunla değişir (PDF, Markdown ve kopya da ekranda
    /// görünen dilde çıkar; önceden hep Türkçe çıkıyordu).
    private var shownRecord: MeetingRecord {
        guard let language = noteLanguage, let shared = record.sharedNotes?[language.rawValue] else {
            return record
        }
        return record.with(note: shared)
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meetingMarkdown(record: shownRecord), forType: .string)
        export = .copied
    }

    /// Notu Mail'de yeni ileti olarak açar (konu toplantı adı, gövde seçili dildeki not); alıcıları kullanıcı seçer.
    private func emailNote() {
        guard let text = displayedShareText, let service = NSSharingService(named: .composeEmail) else {
            export = .failed(String(localized: "Mail açılamadı: Mac'te ayarlı bir e-posta hesabı yok."))
            return
        }
        service.subject = shownRecord.note?.title ?? record.title
        service.perform(withItems: [text])
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
                    .foregroundStyle(.tint)
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
                .foregroundStyle(.tint)
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(.tint)
        case .failed(let message):
            Text(message)
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(.red)
        case .confirmDeleteAudio:
            HStack(spacing: DesignTokens.Spacing.s) {
                Label("Ses kalıcı olarak silinsin mi? Metin ve not kalır; geri alınamaz.", systemImage: "speaker.slash")
                    .foregroundStyle(.red)
                Button("Sesi sil", role: .destructive) {
                    player.stop()
                    model.deleteAudio(meetingID: record.id)
                    export = .none
                }
                Button("Vazgeç") { export = .none }
            }
            .appFont(size: 11, weight: .regular)
            .controlSize(.small)
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
            try meetingPDF(record: shownRecord).write(to: url, options: .atomic)
        }
    }

    /// Paragrafın sesini (iki kayıt karışık) M4A klip olarak İndirilenler'e kaydeder: paylaşılabilir an.
    private func exportClip(paragraph: TranscriptParagraph) {
        let sources: [URL] = playableAudio
        guard !sources.isEmpty else {
            return
        }
        let title: String = "\(record.note?.title ?? record.title) \(timestamp(seconds: paragraph.startSec).replacingOccurrences(of: ":", with: "."))"
        Task {
            do {
                let downloads: URL = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let url: URL = exportFileURL(directory: downloads, title: title, startedAt: record.startedAt, fileExtension: "m4a")
                let range: (start: Double, end: Double) = clipRange(startSec: paragraph.startSec, endSec: paragraph.endSec)
                try await exportAudioClip(sources: sources, startSec: range.start, endSec: range.end, destination: url)
                export = .saved(url)
            } catch {
                meetingsLogger.error("Klip kaydedilemedi, hata: \(String(describing: error), privacy: .private)")
                export = .failed(userFacingMessage(error: error))
            }
        }
    }

    /// Paylaşılabilir tek dosyalık web sayfası (seçili not dilinde) İndirilenler'e.
    private func exportHTML() {
        guard let note = record.note else {
            return
        }
        let shown: (note: MeetingNote, language: ShareLanguage?) = noteLanguage.flatMap { (language: ShareLanguage) -> (note: MeetingNote, language: ShareLanguage?)? in
            record.sharedNotes?[language.rawValue].map { (note: $0, language: language) }
        } ?? (note: note, language: nil)
        export = saveExport(fileExtension: "html") { (url: URL) throws -> Void in
            try Data(meetingHTML(record: record, note: shown.note, language: shown.language).utf8).write(to: url, options: .atomic)
        }
    }

    private func exportMarkdown() {
        export = saveExport(fileExtension: "md") { (url: URL) throws -> Void in
            try Data(meetingMarkdown(record: shownRecord).utf8).write(to: url, options: .atomic)
        }
    }

    /// Notu ve transkripti (seçili not dilinde) Word belgesi olarak İndirilenler'e kaydeder.
    private func exportDOCX() {
        export = saveExport(fileExtension: "docx") { (url: URL) throws -> Void in
            try meetingDOCX(record: shownRecord).write(to: url, options: .atomic)
        }
    }

    /// Transkripti düz metin (`[mm:ss] Ad: metin`) olarak İndirilenler'e kaydeder.
    private func exportTranscriptText() {
        export = saveExport(fileExtension: "txt") { (url: URL) throws -> Void in
            try Data(transcriptText(record: record).utf8).write(to: url, options: .atomic)
        }
    }

    /// Transkripti SRT altyazısı olarak İndirilenler'e kaydeder (videoya eklenebilir).
    private func exportSRT() {
        export = saveExport(fileExtension: "srt") { (url: URL) throws -> Void in
            try Data(transcriptSRT(record: record).utf8).write(to: url, options: .atomic)
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

    /// Çalınabilir kayıtlar ("Sen" ve "Diğerleri"): ses silinmediyse, toplantı kayıtta/işlemede değilse (dosya
    /// yazılıyor olabilir) ve şu an kayıt yapılmıyorsa (çalınan ses mikrofona girip yeni kayda karışmasın).
    private var playableAudio: [URL] {
        guard !record.audioDeleted, !isLocked, !model.isRecording else {
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
    /// İşaretlenen anı ses klibi olarak kaydeder.
    let onClip: @MainActor (TranscriptParagraph) -> Void
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
                NoMyTasksCard(seed: record.id, hasOtherTasks: !others.isEmpty)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SENİN GÖREVLERİN")
                        .appFont(size: 11, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(Theme.muted)
                    // Görev kimliğiyle: liste değişince (ör. tamamlanınca) satır durumu (Anımsatıcılar hatası) başka göreve geçmesin.
                    ForEach(Array(mine.enumerated()), id: \.element.trackingKey) { (item: (offset: Int, element: NoteTask)) in
                        TaskCard(model: model, record: record, task: item.element)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            // Kendi notların ve notu sorarak düzenleme yan yana iki eylem: tek grupta, sıkı aralıkla.
            VStack(alignment: .leading, spacing: 10) {
                MyNotesCard(notes: record.myNotes ?? "", isLocked: model.isLocked(meetingID: record.id)) { (text: String) -> Void in
                    model.saveMyNotes(meetingID: record.id, text: text)
                }
                NoteEditBar(isWorking: model.processingMeetingIDs.contains(record.id)) { (instruction: String) -> Void in
                    model.editNote(meetingID: record.id, instruction: instruction)
                }
            }
            Text(note.summary)
                .font(appearance.readingFont(size: appearance.textSize + 3, weight: .regular))
                .lineSpacing(appearance.lineSpacing + 3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            let markedIDs: Set<String> = highlightedParagraphIDs(paragraphs: paragraphs, highlights: record.highlights ?? [])
            let marked: [TranscriptParagraph] = paragraphs.filter { markedIDs.contains($0.id) }
            if !marked.isEmpty {
                section(title: "İŞARETLEDİĞİN ANLAR", symbol: "bookmark") {
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
                            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contextMenu {
                                Button("Klip olarak kaydet (ses)", systemImage: "waveform") { onClip(paragraph) }
                                    .disabled(!canPlay)
                            }
                        }
                    }
                }
            }
            if let outline = note.outline, !outline.isEmpty {
                section(title: "KONU AKIŞI", symbol: "list.bullet.indent") {
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
                section(title: "KARARLAR", symbol: "checkmark.seal") {
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
                section(title: "DİĞER GÖREVLER", symbol: "checklist") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(others.enumerated()), id: \.element.trackingKey) { (item: (offset: Int, element: NoteTask)) in
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
        let symbols: [String] = ["clock", "person.2", "checkmark.seal", "checklist"]
        return asideCard(title: "BİR BAKIŞTA", symbol: "chart.bar.xaxis") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 14) {
                ForEach(Array(stats.enumerated()), id: \.offset) { (item: (offset: Int, element: (value: String, label: LocalizedStringKey))) in
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: symbols[item.offset])
                            .appFont(size: 12, weight: .semibold)
                            .foregroundStyle(appearance.accent.color)
                            .frame(width: 28, height: 28)
                            .background(appearance.accent.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.element.value).appFont(size: 20, weight: .regular).tracking(-0.4).monospacedDigit()
                            Text(item.element.label).appFont(size: 11, weight: .regular).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
    }

    /// Kim ne kadar konuştu: harf rozeti, ad, pay çubuğu ve yüzde.
    private func talkShare(shares: [SpeakerShare]) -> some View {
        asideCard(title: "KİM NE KADAR KONUŞTU", symbol: "waveform") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(shares, id: \.key) { (share: SpeakerShare) in
                    // Ad ve yüzde üstte, pay çubuğu altta tam genişlikte: dar yan sütunda ad kesilmez.
                    HStack(alignment: .top, spacing: 10) {
                        SpeakerAvatar(text: avatarText(key: share.key, speakerNames: record.speakerNames), color: speakerColor(key: share.key), size: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(speakerName(key: share.key, speakerNames: record.speakerNames))
                                    .appFont(size: 13, weight: .regular)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(String(localized: "\(max(1, Int((share.seconds / 60).rounded()))) dk"))
                                    .appFont(size: 11, weight: .regular)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.muted)
                                    .fixedSize()
                                Text(share.fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))
                                    .appFont(size: 12, weight: .semibold)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.ink)
                                    .fixedSize()
                            }
                            // Pay çubuğu kişinin renginde (gradyanla hafif derinlik).
                            GeometryReader { (proxy: GeometryProxy) in
                                Capsule()
                                    .fill(Theme.soft)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(LinearGradient(colors: [speakerColor(key: share.key).opacity(0.65), speakerColor(key: share.key)], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: max(4, proxy.size.width * share.fraction))
                                    }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
    }

    /// Yan sütun kartı: üstte toplantının kapağından ince film gradyanı şerit, simgeli küçük başlık, içerik.
    private func asideCard(title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title).tracking(DesignTokens.labelTracking)
            } icon: {
                Image(systemName: symbol)
            }
            .appFont(size: 11, weight: .semibold)
            .foregroundStyle(Theme.muted)
            content()
        }
        .padding(16)
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
        // Şerit kartın yuvarlak köşelerini izler: tüm kart boyunca çizilip üst 3 pt'ye maskelenir, kart şekliyle kırpılır.
        .overlay {
            CoverBackground(seed: record.id)
                .mask(alignment: .top) { Rectangle().frame(height: 3) }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)
        }
    }

    /// Bölüm: kart olmadan küçük büyük harfli başlık ve içerik (belge düzeni).
    private func section(title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).tracking(DesignTokens.labelTracking)
            } icon: {
                Image(systemName: symbol)
            }
            .appFont(size: 11, weight: .semibold)
            .foregroundStyle(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Bu toplantıda sana düşen görev yok": toplantının kapağından küçük gradyan simge kutusu, başlık ve kısa açıklama;
/// vurgu renginde çok hafif zemin.
private struct NoMyTasksCard: View {
    let seed: String
    let hasOtherTasks: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 14) {
            Image(systemName: "checkmark")
                .appFont(size: 15, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background { CoverBackground(seed: seed) }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Bu toplantıda sana düşen görev yok")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text(hasOtherTasks ? "Başkalarına düşen görevler ve kararlar aşağıda." : "Özet ve kararlar aşağıda.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(appearance.accent.color.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(appearance.accent.color.opacity(0.18)))
    }
}

/// Notu sorarak düzenle: tek satır istek ("özeti kısalt", "görevlere tarih ekle") ve hazır öneri hapları; düzenlenirken
/// parıltılı "Not düzenleniyor…".
private struct NoteEditBar: View {
    let isWorking: Bool
    let onEdit: @MainActor (String) -> Void
    @State private var instruction: String = ""
    @FocusState private var isFocused: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    /// Hazır istekler (kaynak dilde; gösterilirken ve gönderilirken arayüz diline çevrilir).
    private let suggestions: [String] = ["Özeti kısalt", "Görevlere tarih ekle", "Kararları gerekçeleriyle yaz", "Daha resmi yaz"]

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isWorking ? "sparkles" : "wand.and.stars")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
                TextField(isWorking ? "Not düzenleniyor…" : "Notu değiştir: \"özeti kısalt\", \"görevlere tarih ekle\"…", text: $instruction)
                    .textFieldStyle(.plain)
                    .appFont(size: 13, weight: .regular)
                    .focused($isFocused)
                    .disabled(isWorking)
                    .onSubmit(send)
                if !instruction.isEmpty, !isWorking {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .appFont(size: 11, weight: .bold)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 24, height: 24)
                            .background(Theme.primary, in: Circle())
                    }
                    .buttonStyle(.hoverCapsule)
                    .accessibilityLabel("Notu düzenle")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.card, in: shape)
            .overlay(shape.strokeBorder(isFocused ? appearance.accent.color.opacity(0.45) : Theme.line))
            if isFocused, instruction.isEmpty, !isWorking {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(suggestions, id: \.self) { (suggestion: String) in
                        Button {
                            onEdit(String(localized: String.LocalizationValue(suggestion)))
                        } label: {
                            Text(LocalizedStringKey(suggestion))
                                .appFont(size: 12, weight: .medium)
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.soft, in: Capsule())
                        }
                        .buttonStyle(.hoverPlain)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: isFocused)
    }

    private func send() {
        guard !isWorking else {
            return
        }
        onEdit(instruction)
        instruction = ""
        isFocused = false
    }
}

/// "Senin notların": kullanıcının toplantıda yazdıkları (not bunları öncelik saydı). Düzenlenebilir; "Kaydet ve notu
/// yeniden yaz" notu yeni notlarla baştan yazar. Not yoksa tek satırlık "Kendi notunu ekle".
private struct MyNotesCard: View {
    let notes: String
    let isLocked: Bool
    let onSave: @MainActor (String) -> Void
    @State private var isEditing: Bool = false
    @State private var draft: String = ""
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if notes.isEmpty, !isEditing {
            Button {
                draft = ""
                withAnimation(.smooth(duration: 0.2)) { isEditing = true }
            } label: {
                Label("Kendi notunu ekle — not onu öncelik sayıp yeniden yazılır", systemImage: "square.and.pencil")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.hoverPlain)
            .disabled(isLocked)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Label {
                        Text("SENİN NOTLARIN").tracking(DesignTokens.labelTracking)
                    } icon: {
                        Image(systemName: "square.and.pencil")
                    }
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    Spacer()
                    if isEditing {
                        Button("Vazgeç") { withAnimation(.smooth(duration: 0.2)) { isEditing = false } }
                            .buttonStyle(.hoverPlain)
                            .foregroundStyle(Theme.muted)
                        Button("Kaydet ve notu yeniden yaz") {
                            onSave(draft)
                            withAnimation(.smooth(duration: 0.2)) { isEditing = false }
                        }
                        .buttonStyle(.pillPrimary)
                        .controlSize(.small)
                        // Toplantı işlenirken kayıt reddedilir: taslak kaybolmasın, düğme beklesin.
                        .disabled(isLocked)
                        .hoverHint(isLocked ? "Toplantı işleniyor; bitince kaydedebilirsin" : "Notu bu notlarla yeniden yazar", alignment: .trailing, edge: .bottom)
                    } else {
                        Button("Düzenle", systemImage: "pencil") {
                            draft = notes
                            withAnimation(.smooth(duration: 0.2)) { isEditing = true }
                        }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                        .disabled(isLocked)
                    }
                }
                .appFont(size: 12, weight: .medium)
                if isEditing {
                    TextEditor(text: $draft)
                        .appFont(size: 14, weight: .regular)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90, maxHeight: 220)
                } else {
                    Text(notes)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.accent.color.opacity(0.04), in: shape)
            .overlay(alignment: .leading) {
                // Sol kenarda vurgu çizgisi: bu metin kullanıcının kendi yazdığı.
                UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                    .fill(appearance.accent.color.opacity(0.7))
                    .frame(width: 3)
            }
            .overlay(shape.strokeBorder(Theme.line))
        }
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
            .font(appearance.readingFont(size: appearance.textSize, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func meaning(entry: GlossaryEntry) -> some View {
        Text(entry.meaning)
            .font(appearance.readingFont(size: appearance.textSize, weight: .regular))
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
                    EmptyStateCard(symbol: "exclamationmark.triangle", title: "Çeviri yapılamadı", message: "\(error)")
                    Button("Yeniden dene", systemImage: "arrow.clockwise") {
                        self.error = nil
                        attempt += 1
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("\(language.nativeName) sürümü hazırlanıyor…")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 8)
            }
        }
        // Not yeniden yazılınca ya da kilit kalkınca yeniden denenir (aksi halde bekleme göstergesi takılı kalırdı).
        .task(id: "\(language.rawValue)-\(attempt)-\(record.sharedNotes?[language.rawValue] == nil)-\(note.summary.hashValue)-\(model.isLocked(meetingID: record.id))") {
            // Toplantı işlenirken çevrilmez: sonuç zaten saklanamaz (istek boşa gider); kilit kalkınca görev yeniden çalışır.
            guard record.sharedNotes?[language.rawValue] == nil, error == nil, !model.isLocked(meetingID: record.id) else {
                return
            }
            error = await model.generateSharedNote(meetingID: record.id, language: language)
        }
    }

    private func content(shared: MeetingNote) -> some View {
        let text: String = shareText(record: record, note: shared, language: language)
        let locale: Locale = Locale(identifier: language.rawValue)
        let headings: (summary: String, decisions: String, tasks: String) = (
            summary: language.headings.summary.uppercased(with: locale),
            decisions: language.headings.decisions.uppercased(with: locale),
            tasks: language.headings.tasks.uppercased(with: locale)
        )
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
                    .font(appearance.readingFont(size: appearance.textSize + 2, weight: .regular))
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
                Text(item.title).font(appearance.readingFont(size: appearance.textSize, weight: .semibold))
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
                .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
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
        return DesignTokens.meSpeakerColor
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
    case (.me, nil): DesignTokens.meSpeakerColor
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
        // Sade rozet: konuşmacı rengi yalnızca soluk zeminde ve yazıda (dolu renkli daireler sayfayı fazla renklendiriyordu).
        Text(text)
            .appFont(size: size * 0.42, weight: .semibold)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            // Opak: kapaktaki gradyanın üstünde de okunur.
            .background(Circle().fill(color.opacity(0.15)).background(Circle().fill(Theme.card)))
    }
}

/// Başlık kartındaki konuşmacı zaman çizgisi: kim ne zaman konuştu; çalarken okuma çizgisi; tıklayınca oradan çalar.
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
                        Rectangle().fill(Theme.soft)
                        ForEach(Array(spans.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerSpan)) in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(speakerColor(key: item.element.key))
                                .frame(width: max(2, width * (item.element.endSec - item.element.startSec) / totalSec))
                                .offset(x: width * item.element.startSec / totalSec)
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                    // Konumu yalnızca bu küçük görünüm okur: konuşmacı şeritleri her güncellemede yeniden çizilmez.
                    Playhead(player: player, meetingID: meetingID, width: width, totalSec: totalSec)
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
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12))
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
    /// Paragrafın sesini klip olarak kaydeder (sağ tık).
    let onClip: @MainActor (TranscriptParagraph) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    /// Çalan paragraf: konum her güncellendiğinde değil, yalnızca paragraf değişince yazılır (tüm transkript saniyede
    /// onlarca kez yeniden çizilmesin; kelime vurgusu yalnızca çalan paragrafın içinde güncellenir).
    @State private var activeID: String?

    var body: some View {
        let markedIDs: Set<String> = highlightedParagraphIDs(paragraphs: paragraphs, highlights: record.highlights ?? [])
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
                let isActive: Bool = activeID == paragraph.id
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
                            let marked: Bool = markedIDs.contains(paragraph.id)
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
                        Group {
                            if isActive, !paragraph.words.isEmpty {
                                KaraokeParagraph(words: paragraph.words, player: player, accent: appearance.accent.color)
                            } else {
                                Text(paragraph.text)
                            }
                        }
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
                .background(isActive ? Theme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.easeOut(duration: 0.25), value: isActive)
                .modifier(PlayableTurn(canPlay: canPlay) { onPlay(paragraph.startSec) })
                .contextMenu {
                    Button("Klip olarak kaydet (ses)", systemImage: "waveform") { onClip(paragraph) }
                        .disabled(!canPlay)
                    Button("Metni kopyala", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(paragraph.text, forType: .string)
                    }
                }
                .id(paragraph.id)
            }
        }
        .background {
            PlaybackFollower(player: player, meetingID: record.id, paragraphs: paragraphs) { (id: String?) -> Void in
                activeID = id
                // Çalan paragraf değişince görünür alanın üst üçte birine kaydır (şarkı sözü gibi); alttaki oynatıcı
                // paragrafın sonunu örtmesin.
                if let id, player.isPlaying {
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                }
            }
        }
    }
}

/// Konuşmacı şeridinde çalma konumunu gösteren çizgi.
private struct Playhead: View {
    let player: MeetingAudioPlayer
    let meetingID: String
    let width: CGFloat
    let totalSec: Double

    var body: some View {
        if player.meetingID == meetingID {
            Capsule()
                .fill(Theme.ink)
                .frame(width: 3, height: 14)
                .shadow(color: .black.opacity(0.35), radius: 2)
                .offset(x: width * min(1, max(0, player.currentTime / totalSec)) - 1.5)
        }
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

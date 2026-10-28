import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kayıt sekmesi: boştayken tarih, büyük başlık, canlı film gradyanlı kayıt kartı, görevler ve son toplantılar; kayıtta
/// süre, ses dalgası, konuşmacılı canlı metin ve Türkçesi, "İşaretle" ve "Bitir"; bitince hazırlanma adımları.
struct RecordTab: View {
    let recorder: PhoneRecorder
    let store: PhoneStore
    let router: PhoneRouter
    let calendar: PhoneCalendar

    var body: some View {
        NavigationStack {
            Group {
                switch recorder.phase {
                case .idle, .starting:
                    RecordHome(recorder: recorder, store: store, router: router, calendar: calendar)
                case .recording, .finishing:
                    LiveRecordingView(recorder: recorder)
                }
            }
            .background(Theme.background)
            .animation(.smooth(duration: 0.35), value: recorder.phase == .recording || recorder.phase == .finishing)
        }
    }
}

/// Kayıt öncesi ana ekran.
private struct RecordHome: View {
    let recorder: PhoneRecorder
    let store: PhoneStore
    let router: PhoneRouter
    let calendar: PhoneCalendar

    var body: some View {
        let openTasks: [(record: MeetingRecord, task: NoteTask)] = myTasks(meetings: store.meetings).filter { !isTaskDone(record: $0.record, task: $0.task) }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(interfaceUppercased(text: longDayTitle(date: Date(), locale: interfaceLocale())))
                        .appFont(size: 12, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(Theme.muted)
                    Text("Bugün hangi toplantıyı dinleyelim?")
                        .appFont(size: 30, weight: .regular)
                        .tracking(-0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                RecordHeroCard(recorder: recorder)
                PhoneErrorList(messages: recorder.errorMessages)
                if let id = recorder.lastMeetingID, let step = recorder.processingSteps[id] {
                    PreparingCard(step: step)
                }
                UpcomingCalendarSection(calendar: calendar, router: router)
                if !openTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        PhoneSectionHeader(title: "Sana düşen görevler", actionTitle: "Tümü") { router.tab = .tasks }
                        ForEach(openTasks.prefix(3), id: \.task.trackingKey) { (item: (record: MeetingRecord, task: NoteTask)) in
                            PhoneTaskRow(record: item.record, task: item.task, showsMeeting: true) {
                                withAnimation(.smooth(duration: 0.25)) { store.toggleTask(meetingID: item.record.id, task: item.task) }
                            }
                        }
                    }
                }
                if !store.meetings.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        PhoneSectionHeader(title: "Son toplantılar", actionTitle: "Tümünü gör") { router.tab = .meetings }
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(store.meetings.prefix(6), id: \.id) { (record: MeetingRecord) in
                                    Button {
                                        router.open(meetingID: record.id)
                                    } label: {
                                        PhoneMeetingCard(record: record, height: 150)
                                            .frame(width: 250)
                                    }
                                    .buttonStyle(PressableCardStyle())
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollIndicators(.hidden)
                        .contentMargins(.horizontal, 20, for: .scrollContent)
                        .padding(.horizontal, -20)
                    }
                }
                Label("Telefondaki Teams/Zoom görüşmeleri kaydedilemez (iOS izin vermez); onlar için Mac'i kullan.", systemImage: "info.circle")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// "Salı, 27 Ekim": dilin kendi gün ve ay adlarıyla (bölge biçimi ayı sayıya çevirmesin). Saf fonksiyondur.
func longDayTitle(date: Date, locale: Locale) -> String {
    let formatter: DateFormatter = DateFormatter()
    // Yalnız dil: bölge (ör. Finlandiya) biçimi ayı sayıya çeviriyordu ("Salı 27.10.").
    formatter.locale = Locale(identifier: locale.language.languageCode?.identifier ?? "tr")
    formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
    return formatter.string(from: date)
}

/// Kayıt kartı: yavaşça akan film gradyanı üstünde dil seçimi, büyük cam kayıt düğmesi (nefes alan halka) ve kısa açıklama.
private struct RecordHeroCard: View {
    let recorder: PhoneRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Menu {
                    Button("Otomatik") { recorder.languageMode = .automatic }
                    LanguageMenuItems { (language: MeetingLanguage) -> Void in recorder.setLanguage(language: language) }
                } label: {
                    HStack(spacing: 5) {
                        Text(languageText(locked: nil, mode: recorder.languageMode, isRecording: false))
                        Image(systemName: "chevron.down").appFont(size: 10, weight: .bold)
                    }
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.18), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.28)))
                }
                Spacer()
                GlassChip(text: String(localized: "Yüz yüze"), systemImage: "person.2.fill")
            }
            Button {
                Task { await recorder.start() }
            } label: {
                ZStack {
                    BreathingRing(isActive: !reduceMotion && recorder.phase == .idle)
                    Circle()
                        .fill(.white)
                        .frame(width: 104, height: 104)
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                    if recorder.phase == .starting {
                        ProgressView().controlSize(.large).tint(.black)
                    } else {
                        Image(systemName: "mic.fill")
                            .appFont(size: 38, weight: .medium)
                            .foregroundStyle(Color(red: 0.91, green: 0.36, blue: 0.11))
                    }
                }
                .frame(width: 150, height: 150)
                .contentShape(Circle())
            }
            .buttonStyle(PressableCardStyle())
            .disabled(recorder.phase == .starting)
            .accessibilityLabel("Kaydı başlat")
            VStack(spacing: 4) {
                Text(recorder.phase == .starting ? "Başlatılıyor…" : "Dokun, dinlemeye başlasın")
                    .appFont(size: 20, weight: .semibold)
                    .tracking(-0.3)
                Text("Odadaki herkes konuşmacılara ayrılır, Türkçesi canlı akar; bitince notu yazar.")
                    .appFont(size: 13, weight: .regular)
                    .opacity(0.85)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 1)
        }
        .padding(20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background { FilmGradient(seed: "kayit", palette: .sunset) }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .environment(\.colorScheme, .dark)
    }
}

/// Kayıt düğmesinin çevresinde yavaşça nefes alan beyaz halka.
private struct BreathingRing: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive)) { (context: TimelineViewDefaultContext) in
            let phase: Double = isActive ? (sin(context.date.timeIntervalSinceReferenceDate * 1.6) + 1) / 2 : 0.5
            ZStack {
                Circle()
                    .fill(.white.opacity(0.10 + phase * 0.08))
                    .frame(width: 128 + phase * 18, height: 128 + phase * 18)
                Circle()
                    .strokeBorder(.white.opacity(0.35 - phase * 0.2), lineWidth: 1)
                    .frame(width: 140 + phase * 10, height: 140 + phase * 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Basınca hafifçe küçülen kart/düğme.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Kayıt sırasında: süre, dil, ses dalgası, rıza hatırlatması, konuşmacılı canlı metin (en alta kayar), altta cam
/// çubukta "İşaretle" ve "Bitir".
private struct LiveRecordingView: View {
    let recorder: PhoneRecorder
    @State private var markedAt: Date?
    @State private var isNotesOpen: Bool = false

    private var blocks: [SpeakerBlock] {
        groupBySpeaker(transcript: recorder.transcript.filter { !$0.text.isEmpty })
    }

    var body: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    if recorder.micInterrupted {
                        Label("Mikrofon kesildi (arama ya da alarm). Kesinti bitince kayıt kendiliğinden sürer.", systemImage: "mic.slash.fill")
                            .appFont(size: 14, weight: .medium)
                            .foregroundStyle(.orange)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if recorder.consentReminderVisible {
                        ConsentCard { withAnimation(.smooth(duration: 0.25)) { recorder.consentReminderVisible = false } }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    PhoneErrorList(messages: recorder.errorMessages)
                    if blocks.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform")
                                .appFont(size: 28, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .symbolEffect(.variableColor.iterative, options: .repeating)
                            Text("Dinliyor… Konuşma başlayınca metin burada akar.")
                                .appFont(size: 15, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(blocks) { (block: SpeakerBlock) in
                        LiveBlockView(block: block, translations: recorder.translations)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .animation(.smooth(duration: 0.3), value: blocks.map(\.id))
            }
            .scrollIndicators(.hidden)
            .onChange(of: recorder.transcript) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { controls }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isNotesOpen) {
            PhoneMyNotesSheet(text: Binding<String>(get: { recorder.myNotes }, set: { (text: String) -> Void in recorder.myNotes = text }))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private let bottomID: String = "son"

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RecordingDot(isFinishing: recorder.phase == .finishing)
                if let startedAt = recorder.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                        Text(timestamp(seconds: context.date.timeIntervalSince(startedAt)))
                            .appFont(size: 28, weight: .regular)
                            .tracking(-0.5)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Menu {
                    LanguageMenuItems { (language: MeetingLanguage) -> Void in recorder.setLanguage(language: language) }
                } label: {
                    HStack(spacing: 5) {
                        Text(languageText(locked: recorder.lockedLanguage, mode: recorder.languageMode, isRecording: true))
                        Image(systemName: "chevron.down").appFont(size: 9, weight: .bold)
                    }
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.soft, in: Capsule())
                }
                .disabled(recorder.phase != .recording)
            }
            PhoneLevelBars(levels: recorder.levels)
        }
        .padding(.top, 6)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if recorder.phase == .finishing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Bitiriliyor… Son cümleler ve konuşmacılar tamamlanıyor.")
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                Button {
                    recorder.markMoment()
                    markedAt = Date()
                } label: {
                    Image(systemName: markedAt.map { Date().timeIntervalSince($0) < 2 } == true ? "bookmark.fill" : "bookmark")
                        .appFont(size: 19, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .frame(width: 56, height: 56)
                        .background(Theme.soft, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Bu anı işaretle")
                Button {
                    isNotesOpen = true
                } label: {
                    Image(systemName: recorder.myNotes.isEmpty ? "square.and.pencil" : "square.and.pencil.circle.fill")
                        .appFont(size: 19, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .frame(width: 56, height: 56)
                        .background(Theme.soft, in: Circle())
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Notlarım")
                .sensoryFeedback(.impact(weight: .light), trigger: recorder.highlights.count)
                Button {
                    recorder.stop()
                } label: {
                    Label("Bitir", systemImage: "stop.fill")
                        .appFont(size: 17, weight: .semibold)
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Theme.primary, in: Capsule())
                }
                .buttonStyle(PressableCardStyle())
                .sensoryFeedback(.success, trigger: recorder.phase)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background {
            Rectangle()
                .fill(.bar)
                .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if !recorder.highlights.isEmpty {
                Text("\(recorder.highlights.count) an işaretlendi")
                    .appFont(size: 11, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .offset(y: -10)
            }
        }
    }
}

/// Kayıt noktası: kayıtta yavaşça yanıp söner, bitirilirken durgun.
private struct RecordingDot: View {
    let isFinishing: Bool
    @State private var isDim: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        // Sakin nefes (1,6 sn); hareketi azalt açıkken sabit.
        Circle()
            .fill(isFinishing ? Theme.muted : .red)
            .frame(width: 11, height: 11)
            .opacity(isDim && !reduceMotion ? 0.4 : 1)
            .animation(isFinishing || reduceMotion ? .default : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
            .accessibilityHidden(true)
    }
}

/// Geniş ses dalgası: son seviyeler ortalanmış yuvarlak çubuklar (sessizde alçak).
private struct PhoneLevelBars: View {
    let levels: AudioLevels
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.values.enumerated()), id: \.offset) { (item: (offset: Int, element: Float)) in
                Capsule()
                    .fill(appearance.accent.color.opacity(0.35 + Double(item.element) * 0.65))
                    .frame(maxWidth: .infinity)
                    .frame(height: 4 + CGFloat(item.element) * 34)
            }
        }
        .frame(height: 40)
        .animation(.easeOut(duration: 0.12), value: levels.values)
        .accessibilityHidden(true)
    }
}

/// "Katılımcılara haber ver": kayıt başında, kapatılabilir; Fince ve İngilizce söylenecek cümle.
private struct ConsentCard: View {
    let onDismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .appFont(size: 16, weight: .semibold)
                .foregroundStyle(Color(red: 0.72, green: 0.52, blue: 0.32))
            VStack(alignment: .leading, spacing: 4) {
                Text("Kaydettiğini katılımcılara söyle")
                    .appFont(size: 14, weight: .semibold)
                Text(verbatim: "„Nauhoitan tämän palaverin muistiinpanoja varten.“ · “I'm recording this meeting for my notes.”")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(Theme.soft, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Kapat")
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Bir konuşmacının ardışık cümleleri (sohbet gibi): rozet, ad ve saat; özgün metin (geçici kısım soluk) ve Türkçesi.
private struct LiveBlockView: View {
    let block: SpeakerBlock
    let translations: [SegmentID: String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeakerBadge(speaker: block.speaker, person: block.person, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(speakerLabel(speaker: block.speaker, person: block.person))
                        .appFont(size: 13, weight: .semibold)
                        .foregroundStyle(block.person.map { personColor(person: $0) } ?? Theme.ink)
                    Text(timestamp(seconds: block.startSec))
                        .appFont(size: 11, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Text("\(Text(finalText))\(Text(partialText).foregroundStyle(Theme.muted))")
                    .appFont(size: 17, weight: .regular)
                    .lineSpacing(4)
                if !turkish.isEmpty {
                    Text(turkish)
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.line).frame(width: 2)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var finalText: String {
        block.segments.filter(\.isFinal).map(\.text).joined(separator: " ")
    }

    private var partialText: String {
        let partial: String = block.segments.filter { !$0.isFinal }.map(\.text).joined(separator: " ")
        return finalText.isEmpty || partial.isEmpty ? partial : " " + partial
    }

    private var turkish: String {
        block.segments.compactMap { translations[$0.id] }.joined(separator: " ")
    }
}

/// Toplantı hazırlanıyor: adımlar (biten ✓, süren gösterge, bekleyen soluk) ve ilerleme çubuğu.
private struct PreparingCard: View {
    let step: ProcessingStep
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private let titles: [LocalizedStringKey] = ["Ses kaydı hazırlanıyor", "Kaydın tamamı işleniyor", "Not hazırlanıyor"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Toplantı hazırlanıyor")
                    .appFont(size: 16, weight: .semibold)
                Spacer()
                Text(verbatim: "\(step.rawValue + 1)/\(titles.count)")
                    .appFont(size: 12, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            ProgressView(value: Double(step.rawValue) + 0.5, total: Double(titles.count))
                .tint(appearance.accent.color)
            ForEach(Array(titles.enumerated()), id: \.offset) { (item: (offset: Int, element: LocalizedStringKey)) in
                HStack(spacing: 10) {
                    Group {
                        if item.offset < step.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        } else if item.offset == step.rawValue {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(item.element)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(item.offset > step.rawValue ? Theme.muted : Theme.ink)
                }
            }
            Text("Not hazır olunca Toplantılar'da görünür. Uygulamayı kapatırsan hazırlık sonraki açılışta sürer.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line))
    }
}


/// Kayıt sırasında "Notlarım": kendi notların (madde, başlık); not bunları öncelik sayıp transkriptten tamamlar.
private struct PhoneMyNotesSheet: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notlarım", systemImage: "square.and.pencil")
                .appFont(size: 17, weight: .semibold)
            Text("Önemli gördüğünü kısaca yaz; toplantı bitince not bunları öncelik sayar, gerisini transkriptten tamamlar.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
            TextEditor(text: $text)
                .appFont(size: 16, weight: .regular)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        }
        .padding(20)
        .background(Theme.background)
        .onAppear { isFocused = true }
    }
}

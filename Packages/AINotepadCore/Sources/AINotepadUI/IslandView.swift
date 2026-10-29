import AINotepadCore
import SwiftUI

/// Adanın açılma payı: konuşmacı satırı, iki satır Türkçe ve bir satır orijinal (tasarım belgesi §4.3).
public let islandExpansion: CGFloat = 88
/// Ada kanadının genişliği (açıkken metin satırı bu genişlikte).
public let islandWing: CGFloat = 150

/// Çentiğe yapışık siyah ada (çentiksiz ekranda hap), sakin ve canlı: kapalıyken solda hafifçe atan kayıt noktası ve
/// süre, sağda konuşmaya göre oynayan ses çubukları; açılınca konuşanın renginde, sesle hafifçe büyüyen halkalı rozet
/// ve son cümle yumuşak geçişle. Pencere açılma payını içerir; saydam kısım tıklamaları geçirir. "Hareketi azalt"
/// açıksa hareketler durur.
public struct IslandView: View {
    /// VoiceOver'ın okuduğu ad (uygulamanın görünen adı).
    let appName: String
    let state: LiveViewState
    /// Ses seviyeleri (ses çubukları, rozet halkası ve parıltı).
    let levels: AudioLevels
    let layout: IslandLayout
    let isExpanded: Bool
    let onTap: @MainActor () -> Void
    /// Fare adanın (saydam pay değil) üstüne gelince/çıkınca çağrılır.
    let onHover: @MainActor (Bool) -> Void
    /// Sağ tık menüsündeki "Kaydı durdur" (ada menü çubuğu ikonlarını örtebildiği için).
    let onStop: @MainActor () -> Void
    /// Sağ tık menüsünden toplantı dilini değiştirme.
    let onSetLanguage: @MainActor (MeetingLanguage) -> Void

    public init(
        appName: String,
        state: LiveViewState,
        levels: AudioLevels,
        layout: IslandLayout,
        isExpanded: Bool,
        onTap: @escaping @MainActor () -> Void,
        onHover: @escaping @MainActor (Bool) -> Void,
        onStop: @escaping @MainActor () -> Void,
        onSetLanguage: @escaping @MainActor (MeetingLanguage) -> Void
    ) {
        self.appName = appName
        self.state = state
        self.levels = levels
        self.layout = layout
        self.isExpanded = isExpanded
        self.onTap = onTap
        self.onHover = onHover
        self.onStop = onStop
        self.onSetLanguage = onSetLanguage
    }

    public var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(width: layout.frame.width, height: layout.frame.height, alignment: .top)
    }

    private var island: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.s) {
                IslandStatus(state: state)
                Spacer(minLength: 0)
                if !state.errors.isEmpty {
                    // Panel gizliyken de sorun fark edilsin.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .appFont(size: 11, weight: .semibold)
                        .foregroundStyle(NoticeSeverity.error.tint)
                        .accessibilityLabel("Hata var")
                }
                if isExpanded {
                    Text(state.languageText)
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .transition(.blurReplace)
                }
                IslandEqualizer(levels: levels, isActive: state.isRecording && !state.isPaused)
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .frame(height: layout.collapsedHeight)
            if isExpanded {
                expandedContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.l)
                    .padding(.top, 2)
                    .padding(.bottom, DesignTokens.Spacing.m)
                    .frame(height: islandExpansion, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.frame.width, height: isExpanded ? layout.collapsedHeight + islandExpansion : layout.collapsedHeight, alignment: .top)
        .background(.black, in: islandShape)
        .contentShape(islandShape)
        .onTapGesture { onTap() }
        .linkPointer(isEnabled: true)
        .contextMenu {
            Button("Kaydı durdur", systemImage: "stop.circle") { onStop() }
                .disabled(!state.isRecording)
            Menu("Dili değiştir", systemImage: "globe") {
                LanguageMenuItems(onSetLanguage: onSetLanguage)
            }
            .disabled(!state.isRecording)
            Button("Paneli göster / gizle", systemImage: "rectangle.on.rectangle") { onTap() }
        }
        // VoiceOver: ada tek düğme; durum, dil ve son cümle okunur.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: appName))
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Paneli gösterir ya da gizler")
        .accessibilityAction(named: "Kaydı durdur") { onStop() }
        .onHover { (hovering: Bool) -> Void in onHover(hovering) }
        .animation(.spring(response: 0.42, dampingFraction: 0.74), value: isExpanded)
    }

    /// Açık ada: kim konuşuyor (renkli nokta + ad), ne dedi (Türkçesi, iki satır), şu an ne diyor (orijinal, tek
    /// satır, soluk). En yeni kelimeler görünsün diye satırlar baştan kısaltılır. Hata varsa orijinal yerine hata satırı.
    @ViewBuilder
    private var expandedContent: some View {
        if let line = state.islandLine {
            HStack(alignment: .top, spacing: 10) {
                IslandSpeakerBadge(speaker: line.speaker, person: line.person, levels: levels)
                VStack(alignment: .leading, spacing: 3) {
                    Text(interfaceUppercased(text: speakerLabel(speaker: line.speaker, person: line.person)))
                        .appFont(size: 10.5, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(line.person.map { personColor(person: $0).mix(with: .white, by: 0.35) } ?? Color.white.opacity(0.6))
                        .contentTransition(.opacity)
                    Text(line.primary)
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(.white.opacity(line.primaryIsOriginal ? 0.75 : 0.98))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.25), value: line.primary)
                    if let error = state.errors.last {
                        Text(error)
                            .appFont(size: 11, weight: .regular)
                            .foregroundStyle(NoticeSeverity.error.tint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let secondary = line.secondary {
                        Text(secondary)
                            .appFont(size: 11.5, weight: .regular)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(.white.opacity(0.6))
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    Text("Dinliyor… konuşma başlayınca burada akar")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(.white.opacity(0.55))
                }
                if let error = state.errors.last {
                    Text(error)
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(NoticeSeverity.error.tint)
                        .lineLimit(2)
                }
            }
        }
    }

    private var accessibilitySummary: String {
        let status: String = switch state.phase {
        case .recording: String(localized: "Kayıtta")
        case .finishing: String(localized: "Bitiriliyor")
        case .idle: state.statusText
        }
        return [status, state.languageText, state.latestOthersSentence ?? "", state.errors.last ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Çentikte üst köşeler ekrana yapışık (düz), çentiksiz hapta tüm köşeler yuvarlak.
    private var islandShape: UnevenRoundedRectangle {
        let top: CGFloat = layout.hasNotch ? 0 : 16
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: top)
    }
}


/// Adanın sol kanadı: kayıtta haleli kırmızı nokta ve süre; duraklatılınca turuncu; bitirilirken dönen yay.
private struct IslandStatus: View {
    let state: LiveViewState

    var body: some View {
        Group {
            if state.phase == .finishing {
                HStack(spacing: 7) {
                    IslandSpinner()
                    Text("Bitiriliyor…").appFont(size: 12, weight: .medium)
                }
            } else if state.isRecording, state.isPaused {
                Label("Duraklatıldı", systemImage: "pause.circle.fill")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(NoticeSeverity.attention.tint)
            } else if state.isRecording, let startedAt = state.startedAt {
                HStack(spacing: 7) {
                    // Durağan nokta ve sabit hale: kayıt boyunca saniyede 30 kez yeniden çizim pil tüketiyordu.
                    ZStack {
                        Circle().fill(Color.red.opacity(0.25)).frame(width: 13, height: 13)
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                    }
                    .frame(width: 17, height: 17)
                    TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                        Text(timestamp(seconds: context.date.timeIntervalSince(startedAt)))
                            .appFont(size: 12, weight: .semibold)
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: false))
                            .animation(.snappy(duration: 0.25), value: Int(context.date.timeIntervalSince(startedAt)))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Kayıtta")
            } else {
                Text(state.statusText).appFont(size: 12, weight: .medium).foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
    }
}

/// Bitirilirken dönen ince yay.
private struct IslandSpinner: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { (context: TimelineViewDefaultContext) in
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(appearance.accent.color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }
        .accessibilityHidden(true)
    }
}

/// Sağ kanattaki canlı ses çubukları: son beş seviye, ortadan büyüyen yuvarlak çubuklar (vurgudan pembeye).
private struct IslandEqualizer: View {
    let levels: AudioLevels
    let isActive: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let recent: [Float] = Array(levels.values.suffix(5))
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(recent.enumerated()), id: \.offset) { (item: (offset: Int, element: Float)) in
                Capsule()
                    .fill(LinearGradient(colors: [appearance.accent.color, Color(red: 0.95, green: 0.45, blue: 0.62)], startPoint: .bottom, endPoint: .top))
                    .frame(width: 3, height: isActive ? 3 + CGFloat(min(1, item.element * 1.4)) * 13 : 3)
            }
        }
        .frame(width: 26, height: 16)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: recent)
        .accessibilityHidden(true)
    }
}

/// Açık adada konuşanın rozeti: kişinin renginde daire ve numarası; çevresindeki halka sesle büyür.
private struct IslandSpeakerBadge: View {
    let speaker: Speaker
    let person: Int?
    let levels: AudioLevels

    var body: some View {
        let color: Color = person.map { personColor(person: $0) } ?? DesignTokens.meSpeakerColor
        let level: CGFloat = CGFloat(levels.values.last ?? 0)
        ZStack {
            Circle()
                .strokeBorder(color.opacity(0.55), lineWidth: 1.5)
                .frame(width: 30 + level * 5, height: 30 + level * 5)
                .opacity(0.3 + Double(level) * 0.4)
            Circle()
                .fill(color.mix(with: .black, by: 0.2))
                .frame(width: 28, height: 28)
            if let person {
                Text(verbatim: "\(person)")
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(.white)
            } else {
                Image(systemName: speaker == .me ? "person.fill" : "person.2.fill")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 40, height: 40)
        .animation(.spring(response: 0.2, dampingFraction: 0.55), value: level)
        .contentTransition(.opacity)
        .accessibilityHidden(true)
    }
}

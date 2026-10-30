import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Widget eklentisi: kaydın canlı etkinliği, Denetim Merkezi düğmesi ve ana ekran / kilit ekranı widget'ı.
@main
struct AINotepadWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordControl()
        QuickRecordWidget()
    }
}

/// Uygulamanın turuncu vurgusu (Mac'teki varsayılan vurgu).
private let accent: Color = Color(red: 0.91, green: 0.36, blue: 0.11)

/// Kayıt sürerken kilit ekranı ve Dynamic Island: kırmızı nokta ve süre, son cümle (konuşmacısıyla), "Bitir".
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { (context: ActivityViewContext<RecordingActivityAttributes>) in
            LockScreenRecording(context: context)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { (context: ActivityViewContext<RecordingActivityAttributes>) in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StopButton(isFinishing: context.state.isFinishing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LastLine(state: context.state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }
}

/// Kilit ekranındaki kart.
private struct LockScreenRecording: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(context.state.isFinishing ? "Bitiriliyor…" : "Kaydediliyor")
                    .font(.system(size: 14, weight: .semibold))
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                StopButton(isFinishing: context.state.isFinishing)
            }
            LastLine(state: context.state)
        }
        .foregroundStyle(.white)
    }
}

/// Son kesinleşen cümle; henüz yoksa "Dinliyor…".
private struct LastLine: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !state.speaker.isEmpty {
                Text(state.speaker)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text(state.lastLine.isEmpty ? String(localized: "Dinliyor…") : state.lastLine)
                .font(.system(size: 14))
                .lineLimit(2)
                .foregroundStyle(.white.opacity(state.lastLine.isEmpty ? 0.6 : 0.95))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kaydı uygulamayı açmadan bitiren düğme; bitirilirken gizlenir.
private struct StopButton: View {
    let isFinishing: Bool

    var body: some View {
        if !isFinishing {
            Button(intent: StopRecordingIntent()) {
                Label("Bitir", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
        }
    }
}

/// Denetim Merkezi ve Eylem düğmesi: "Toplantıyı kaydet".
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.senoldogan.AINotepad.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Toplantıyı kaydet", systemImage: "mic.fill")
            }
        }
        .displayName("Toplantıyı kaydet")
        .description("AI-Notepad'i açar ve yüz yüze toplantıyı kaydetmeye başlar.")
    }
}

/// Ana ekran ve kilit ekranı widget'ı: tek dokunuşla kayıt.
struct QuickRecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.senoldogan.AINotepad.quickRecord", provider: QuickRecordProvider()) { (_: QuickRecordEntry) in
            QuickRecordView()
                .containerBackground(for: .widget) { Color(red: 0.99, green: 0.99, blue: 0.99) }
        }
        .configurationDisplayName("Toplantıyı kaydet")
        .description("Tek dokunuşla yüz yüze toplantıyı kaydetmeye başla.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

/// Widget içeriği değişmez: tek bir giriş yeter.
struct QuickRecordEntry: TimelineEntry {
    let date: Date
}

struct QuickRecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickRecordEntry {
        QuickRecordEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickRecordEntry) -> Void) {
        completion(QuickRecordEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickRecordEntry>) -> Void) {
        completion(Timeline(entries: [QuickRecordEntry(date: Date())], policy: .never))
    }
}

/// Küçük widget: turuncu mikrofon dairesi ve "Toplantıyı kaydet"; kilit ekranında yalnız daire.
private struct QuickRecordView: View {
    @Environment(\.widgetFamily) private var family: WidgetFamily

    var body: some View {
        Button(intent: StartRecordingIntent()) {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "mic.fill").font(.system(size: 22, weight: .semibold))
                }
                // Yalnız simge var: VoiceOver simgenin adını değil eylemi okusun.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Toplantıyı kaydet"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        Circle().fill(accent).frame(width: 52, height: 52)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 0)
                    Text("Toplantıyı kaydet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
                    Text("AI-Notepad")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

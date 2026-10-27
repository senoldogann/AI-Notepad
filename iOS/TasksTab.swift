import AINotepadCore
import AINotepadUI
import SwiftUI

/// Görevler sekmesinin süzgeci.
private enum TaskFilter: Hashable {
    case open
    case done
}

/// Görevlerim: toplantı notlarında sana yazılan işler; açık ya da tamamlanan, toplantıya göre gruplu (en yeni toplantı
/// önce), üstte ilerleme. İşaretlenince toplantıya yazılır (Mac'te de aynı işaret görünür); toplantı adına dokununca
/// toplantı açılır.
struct TasksTab: View {
    let store: PhoneStore
    let router: PhoneRouter
    @State private var filter: TaskFilter = .open
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let all: [(record: MeetingRecord, task: NoteTask)] = myTasks(meetings: store.meetings)
        let doneCount: Int = all.filter { isTaskDone(record: $0.record, task: $0.task) }.count
        let shown: [(record: MeetingRecord, task: NoteTask)] = all.filter { isTaskDone(record: $0.record, task: $0.task) == (filter == .done) }
        let groups: [(record: MeetingRecord, tasks: [NoteTask])] = shown.reduce(into: [(record: MeetingRecord, tasks: [NoteTask])]()) { (result: inout [(record: MeetingRecord, tasks: [NoteTask])], item: (record: MeetingRecord, task: NoteTask)) -> Void in
            if let last = result.last, last.record.id == item.record.id {
                result[result.count - 1] = (record: last.record, tasks: last.tasks + [item.task])
            } else {
                result.append((record: item.record, tasks: [item.task]))
            }
        }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !all.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: "\(doneCount)/\(all.count)")
                                    .appFont(size: 30, weight: .regular)
                                    .tracking(-0.6)
                                    .monospacedDigit()
                                Text("tamamlandı")
                                    .appFont(size: 14, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                            }
                            ProgressView(value: Double(doneCount), total: Double(max(all.count, 1)))
                                .tint(appearance.accent.color)
                        }
                    }
                    PillTabs(selection: $filter, options: [
                        (TaskFilter.open, "Açık · \(all.count - doneCount)"),
                        (TaskFilter.done, "Tamamlanan · \(doneCount)"),
                    ])
                    if shown.isEmpty {
                        if filter == .done {
                            EmptyStateCard(symbol: "checkmark.circle", title: "Henüz tamamlanan yok", message: "Bir görevin dairesine dokununca buraya taşınır.")
                        } else if doneCount > 0 {
                            EmptyStateHero(
                                symbol: "party.popper.fill", title: "Açık görevin kalmadı",
                                message: "Hepsi tamamlandı. Yeni toplantılarda sana düşen işler buraya gelir.", palette: .sunset, steps: []
                            ) {
                                EmptyView()
                            }
                            .overlay { ConfettiBurst(palette: .sunset) }
                        } else {
                            EmptyStateHero(
                                symbol: "checklist", title: "Henüz sana düşen görev yok",
                                message: "Toplantı bitince not yazılır; içinde senin adına yazılan işler burada toplanır.",
                                palette: .mint,
                                steps: [
                                    EmptyStateStep(symbol: "mic.fill", title: "Kayıt"),
                                    EmptyStateStep(symbol: "sparkles", title: "Not yazılır"),
                                    EmptyStateStep(symbol: "checkmark.circle", title: "Görevlerin burada"),
                                ]
                            ) {
                                if phoneUserName().isEmpty {
                                    Button("Adını yaz (görevlerin tanınsın)", systemImage: "person.text.rectangle") { router.tab = .settings }
                                        .buttonStyle(.pillPrimary)
                                }
                            }
                        }
                    }
                    ForEach(groups, id: \.record.id) { (group: (record: MeetingRecord, tasks: [NoteTask])) in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                router.open(meetingID: group.record.id)
                            } label: {
                                HStack(spacing: 8) {
                                    CoverBackground(seed: group.record.id)
                                        .frame(width: 18, height: 18)
                                        .clipShape(Circle())
                                    Text(group.record.note?.title ?? group.record.title)
                                        .appFont(size: 13, weight: .semibold)
                                        .lineLimit(1)
                                    Text(group.record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale())))
                                        .appFont(size: 12, weight: .regular)
                                        .foregroundStyle(Theme.muted)
                                    Image(systemName: "chevron.right")
                                        .appFont(size: 10, weight: .semibold)
                                        .foregroundStyle(Theme.muted)
                                }
                                .foregroundStyle(Theme.ink)
                            }
                            .buttonStyle(.plain)
                            ForEach(group.tasks, id: \.trackingKey) { (task: NoteTask) in
                                PhoneTaskRow(record: group.record, task: task, showsMeeting: false) {
                                    withAnimation(.smooth(duration: 0.25)) {
                                        store.toggleTask(meetingID: group.record.id, task: task)
                                    }
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .animation(.smooth(duration: 0.3), value: shown.map(\.task.trackingKey))
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .navigationTitle("Görevlerim")
        }
    }
}

/// Görev satırı: tamamlandı kutusu, iş, sahibi ve tarihi; istenirse toplantı adı.
struct PhoneTaskRow: View {
    let record: MeetingRecord
    let task: NoteTask
    let showsMeeting: Bool
    let onToggle: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let isDone: Bool = isTaskDone(record: record, task: task)
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .appFont(size: 22, weight: .regular)
                    .foregroundStyle(isDone ? appearance.accent.color : Theme.muted)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Tamamlanmadı olarak işaretle" : "Tamamlandı olarak işaretle")
            VStack(alignment: .leading, spacing: 3) {
                Text(task.description)
                    .appFont(size: 15, weight: .regular)
                    .strikethrough(isDone, color: Theme.muted)
                    .foregroundStyle(isDone ? Theme.muted : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: isDone)
    }

    private var detail: String {
        let meeting: [String] = showsMeeting ? [record.note?.title ?? record.title] : []
        return ([task.owner] + [task.dueDate].compactMap { $0 } + meeting).joined(separator: " · ")
    }
}

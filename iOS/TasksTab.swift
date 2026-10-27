import AINotepadCore
import AINotepadUI
import SwiftUI

/// Görevler sekmesinin süzgeci.
private enum TaskFilter: Hashable {
    case open
    case done
}

/// Görevlerim: toplantı notlarında sana yazılan işler (en yeni toplantı önce); açık ya da tamamlanan. İşaretlenince
/// toplantıya yazılır (Mac'te de aynı işaret görünür); satıra dokununca toplantı açılır.
struct TasksTab: View {
    let store: PhoneStore
    let router: PhoneRouter
    @State private var filter: TaskFilter = .open

    var body: some View {
        let all: [(record: MeetingRecord, task: NoteTask)] = myTasks(meetings: store.meetings)
        let shown: [(record: MeetingRecord, task: NoteTask)] = all.filter { isTaskDone(record: $0.record, task: $0.task) == (filter == .done) }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Görevler", selection: $filter) {
                        Text("Açık · \(all.count - all.filter { isTaskDone(record: $0.record, task: $0.task) }.count)").tag(TaskFilter.open)
                        Text("Tamamlanan · \(all.filter { isTaskDone(record: $0.record, task: $0.task) }.count)").tag(TaskFilter.done)
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 6)
                    if shown.isEmpty {
                        EmptyStateCard(
                            symbol: "checklist",
                            title: filter == .open ? "Açık görevin yok" : "Henüz tamamlanan yok",
                            message: "Toplantı notlarında senin adına yazılan işler burada toplanır."
                        )
                    }
                    ForEach(shown, id: \.task.trackingKey) { (item: (record: MeetingRecord, task: NoteTask)) in
                        PhoneTaskRow(record: item.record, task: item.task, showsMeeting: true) {
                            withAnimation(.smooth(duration: 0.25)) {
                                store.toggleTask(meetingID: item.record.id, task: item.task)
                            }
                        }
                        .onTapGesture { router.open(meetingID: item.record.id) }
                    }
                }
                .padding(16)
            }
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    private var detail: String {
        let meeting: [String] = showsMeeting ? [record.note?.title ?? record.title] : []
        return ([task.owner] + [task.dueDate].compactMap { $0 } + meeting).joined(separator: " · ")
    }
}

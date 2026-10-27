import AINotepadCore
import AINotepadUI
import SwiftUI

/// Toplantılar: film gradyanlı kartlar (en yeni önce); dokununca toplantının notu.
struct MeetingsTab: View {
    let store: PhoneStore
    /// `--toplanti <kimlik>` başlatma argümanı toplantıyı doğrudan açar (görsel kontrol için).
    @State private var path: [String] = CommandLine.arguments.firstIndex(of: "--toplanti").flatMap { (index: Int) -> [String]? in
        CommandLine.arguments.indices.contains(index + 1) ? [CommandLine.arguments[index + 1]] : nil
    } ?? []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(store.problems, id: \.self) { (problem: String) in
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.meetings.isEmpty {
                        EmptyStateCard(
                            symbol: "list.bullet.rectangle", title: "Henüz toplantı yok",
                            message: "Kayıt sekmesinden yüz yüze bir toplantıyı kaydet; Mac'teki toplantıların da iCloud eşitlemesiyle burada görünecek."
                        )
                    }
                    ForEach(store.meetings, id: \.id) { (record: MeetingRecord) in
                        NavigationLink(value: record.id) {
                            MeetingCard(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle("Toplantılar")
            .navigationDestination(for: String.self) { (id: String) in
                if let record = store.meetings.first(where: { $0.id == id }) {
                    MeetingReadView(record: record)
                }
            }
            .refreshable { store.reload() }
        }
    }
}

/// Toplantı kartı: kapak gradyanı üstünde başlık, tarih ve süre.
private struct MeetingCard: View {
    let record: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text(record.note?.title ?? record.title)
                .appFont(size: 17, weight: .semibold)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(cardSubtitle)
                .appFont(size: 12, weight: .regular)
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .bottomLeading)
        .background { CoverBackground(seed: record.id) }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cardSubtitle: String {
        let date: String = record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))
        let minutes: [String] = meetingDurationMinutes(record: record).map { [String(localized: "\($0) dk")] } ?? []
        return ([date] + minutes).joined(separator: " · ")
    }
}

/// Toplantının notu (okuma): kapak, senin görevlerin, özet, kararlar, diğer görevler. Çalma ve transkript aşama 3'te.
struct MeetingReadView: View {
    let record: MeetingRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(interfaceLocale())).uppercased(with: interfaceLocale()))
                        .appFont(size: 11, weight: .medium)
                        .tracking(0.6)
                        .opacity(0.85)
                    Text(record.note?.title ?? record.title)
                        .appFont(size: 26, weight: .regular)
                        .tracking(-0.4)
                }
                .foregroundStyle(.white)
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .bottomLeading)
                .background { LivingCoverBackground(seed: record.id) }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                if let note = record.note {
                    let mine: [NoteTask] = note.tasks.filter(\.isMine)
                    if !mine.isEmpty {
                        section(title: "SENİN GÖREVLERİN") { taskList(tasks: mine) }
                    }
                    Text(note.summary)
                        .appFont(size: 17, weight: .regular)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                    if !note.decisions.isEmpty {
                        section(title: "KARARLAR") {
                            ForEach(Array(note.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                                Text("• " + item.element).appFont(size: 15, weight: .regular)
                            }
                        }
                    }
                    let others: [NoteTask] = note.tasks.filter { !$0.isMine }
                    if !others.isEmpty {
                        section(title: "DİĞER GÖREVLER") { taskList(tasks: others) }
                    }
                } else {
                    EmptyStateCard(symbol: "doc.text", title: "Bu toplantının notu yok", message: nil)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
            content()
        }
    }

    private func taskList(tasks: [NoteTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(tasks.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.element.description).appFont(size: 15, weight: .regular)
                    Text(([item.element.owner] + [item.element.dueDate].compactMap { $0 }).joined(separator: " · "))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

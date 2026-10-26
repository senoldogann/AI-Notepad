import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kişiler: toplantılarda adı verilen konuşmacılar. Solda liste (son görüldüğü toplantıya göre), sağda kişinin
/// toplantıları (konuşma payıyla), adına yazılan görevler ve sesinden tanınıp tanınmadığı.
struct PeoplePage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var selected: String?

    var body: some View {
        let people: [PersonSummary] = peopleDirectory(
            records: model.meetings, voices: model.registeredVoices,
            userName: UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        )
        if people.isEmpty {
            VStack {
                EmptyStateCard(
                    symbol: "person.2", title: "Henüz adı verilmiş konuşmacı yok",
                    message: "Bir toplantının Transkript sekmesinde konuşmacıya ad verince kişi burada görünür; sesi hatırlanır ve sonraki toplantılarda adıyla tanınır."
                )
                .frame(maxWidth: 620)
                Spacer()
            }
            .padding(36)
        } else {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(people) { (person: PersonSummary) in
                            row(person: person, isSelected: (selected ?? people.first?.id) == person.id)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 280)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                if let person = people.first(where: { $0.id == (selected ?? people.first?.id) }) {
                    PersonDetail(person: person, router: router)
                        .id(person.id)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: selected)
        }
    }

    private func row(person: PersonSummary, isSelected: Bool) -> some View {
        Button {
            selected = person.id
        } label: {
            HStack(spacing: 10) {
                PersonAvatar(name: person.name, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).appFont(size: 14, weight: .medium).lineLimit(1)
                    Text("\(person.meetings.count) toplantı").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                if person.hasVoiceprint {
                    Image(systemName: "waveform.badge.checkmark")
                        .foregroundStyle(Theme.muted)
                        .hoverHint("Sesinden tanınıyor", alignment: .trailing, edge: .bottom)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
    }
}

/// Addan sabit renkli harf rozeti.
struct PersonAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let hash: Int = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .appFont(size: size * 0.42, weight: .semibold)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(personColor(person: hash % DesignTokens.personPalette.count + 1), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Kişinin sayfası: başlık (rozet, ad, sesi), özet sayılar, toplantıları ve görevleri.
private struct PersonDetail: View {
    let person: PersonSummary
    let router: MainWindowRouter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    PersonAvatar(name: person.name, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name).appFont(size: 28, weight: .regular).tracking(-0.4)
                        Label(person.hasVoiceprint ? "Sesinden tanınıyor" : "Sesi henüz kayıtlı değil", systemImage: person.hasVoiceprint ? "waveform.badge.checkmark" : "waveform")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                }
                HStack(spacing: 12) {
                    stat(value: "\(person.meetings.count)", label: "toplantı")
                    stat(value: String(localized: "\(max(1, Int((person.totalSeconds / 60).rounded()))) dk"), label: "konuşma")
                    stat(value: "\(person.tasks.count)", label: "görev")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("TOPLANTILARI").appFont(size: 11, weight: .semibold).tracking(DesignTokens.labelTracking).foregroundStyle(Theme.muted)
                    VStack(spacing: 0) {
                        ForEach(Array(person.meetings.enumerated()), id: \.offset) { (item: (offset: Int, element: PersonMeeting)) in
                            if item.offset > 0 {
                                Rectangle().fill(Theme.line).frame(height: 1)
                            }
                            Button {
                                router.selectedMeetingID = item.element.meetingID
                                router.section = .meetings
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.element.title).appFont(size: 14, weight: .medium).lineLimit(1)
                                        Text(item.element.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                                            .appFont(size: 12, weight: .regular)
                                            .foregroundStyle(Theme.muted)
                                    }
                                    Spacer(minLength: 8)
                                    Text(item.element.fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))
                                        .appFont(size: 12, weight: .medium)
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.muted)
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverPlain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .cardSurface(cornerRadius: 14)
                }
                if !person.tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("GÖREVLERİ").appFont(size: 11, weight: .semibold).tracking(DesignTokens.labelTracking).foregroundStyle(Theme.muted)
                        ForEach(Array(person.tasks.enumerated()), id: \.offset) { (item: (offset: Int, element: PersonTask)) in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.element.task.description).appFont(size: 14, weight: .regular).fixedSize(horizontal: false, vertical: true)
                                Text(([item.element.task.dueDate].compactMap { $0 } + [item.element.meetingTitle]).joined(separator: " · "))
                                    .appFont(size: 12, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(cornerRadius: 12)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).appFont(size: 22, weight: .regular).tracking(-0.4)
            Text(label).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
    }
}

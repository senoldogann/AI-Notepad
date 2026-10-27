import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kişiler: toplantılarda adı verilen konuşmacılar ve elle eklenenler. Solda arama, "Kişi ekle" ve liste (son
/// görüldüğü toplantıya göre), sağda kişinin sayfası (düzenle, kaldır) ya da ekleme formu.
struct PeoplePage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var selected: String?
    @State private var isAdding: Bool = false
    @State private var filter: String = ""

    var body: some View {
        let people: [PersonSummary] = peopleDirectory(
            records: model.meetings, voices: model.registeredVoices, book: model.peopleBook,
            userName: UserDefaults.standard.string(forKey: SettingsKey.userName) ?? ""
        )
        let query: String = filter.trimmingCharacters(in: .whitespaces)
        let shown: [PersonSummary] = query.isEmpty ? people : people.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.role.localizedCaseInsensitiveContains(query)
        }
        let current: PersonSummary? = people.first { $0.id == selected } ?? people.first
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        TextField("Kişi ara", text: $filter).textFieldStyle(.plain)
                    }
                    .appFont(size: 13, weight: .regular)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { isAdding = true }
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .appFont(size: 14, weight: .medium)
                            .frame(width: 32, height: 30)
                    }
                    .buttonStyle(.hoverPlain)
                    .accessibilityLabel("Kişi ekle")
                    .hoverHint("Kişi ekle", alignment: .trailing, edge: .bottom)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
                if let error = model.peopleBookError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { (person: PersonSummary) in
                            row(person: person, isSelected: !isAdding && current?.id == person.id)
                        }
                        if shown.isEmpty, !people.isEmpty {
                            Text("Eşleşen kişi yok")
                                .appFont(size: 13, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .padding(12)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(width: 280)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
            Group {
                if isAdding {
                    PersonForm(title: "Kişi ekle", initialName: "", lockedName: nil, initialRole: "", initialEmail: "") { (name: String, role: String, email: String) -> Void in
                        model.savePerson(name: name, role: role, email: email)
                        selected = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        isAdding = false
                    } onCancel: {
                        isAdding = false
                    }
                    .transition(.opacity)
                } else if let current {
                    PersonDetail(person: current, router: router) { (name: String, role: String, email: String) -> Void in
                        // Elle eklenen kişinin adı değişebilir (sesi de taşınır); toplantıdan gelen kişinin adı
                        // toplantılarda verildiği için formda kilitlidir, yalnızca ünvan ve e-posta kaydedilir.
                        // Toplantılarda adı geçen kişinin adı toplantılarda verildiği için değişmez (değişirse kişi ikiye
                        // bölünürdü); yalnızca toplantısız, elle eklenen kişinin adı değişir.
                        if current.isSaved, current.meetings.isEmpty {
                            model.renamePerson(oldName: current.name, name: name, role: role, email: email)
                            selected = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        } else {
                            model.savePerson(name: current.name, role: role, email: email)
                            selected = current.id
                        }
                    } onRemove: {
                        model.removePerson(name: current.name)
                        selected = nil
                    }
                    .id(current.id)
                    .transition(.opacity)
                } else {
                    ScrollView {
                        EmptyStateHero(
                            symbol: "person.2.fill", title: "Henüz kimse yok",
                            message: "Konuşmacıya bir kez ad ver; kişi burada görünür, toplantıları, konuşma payı ve görevleriyle. Sık görüştüğün kişileri şimdiden ekleyebilirsin; adları konuşma tanımaya da verilir.",
                            palette: .violet,
                            steps: [
                                EmptyStateStep(symbol: "doc.text", title: "Toplantının transkriptini aç"),
                                EmptyStateStep(symbol: "character.cursor.ibeam", title: "Konuşmacıya ad ver"),
                                EmptyStateStep(symbol: "person.crop.circle.badge.checkmark", title: "Kişi burada toplanır"),
                            ]
                        ) {
                            Button("Kişi ekle", systemImage: "person.badge.plus") {
                                withAnimation(.smooth(duration: 0.25)) { isAdding = true }
                            }
                            .buttonStyle(.pillPrimary)
                        }
                        .padding(.top, 24)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.smooth(duration: 0.25), value: selected)
        .animation(.smooth(duration: 0.25), value: isAdding)
    }

    private func row(person: PersonSummary, isSelected: Bool) -> some View {
        Button {
            isAdding = false
            selected = person.id
        } label: {
            HStack(spacing: 10) {
                PersonAvatar(name: person.name, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).appFont(size: 14, weight: .medium).lineLimit(1)
                    Group {
                        if !person.role.isEmpty {
                            Text(person.role)
                        } else if person.meetings.isEmpty {
                            Text("Henüz toplantı yok")
                        } else {
                            Text("\(person.meetings.count) toplantı")
                        }
                    }
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
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

/// Kişi ekleme/düzenleme formu: ad (zorunlu), ünvan ya da kurum, e-posta. `lockedName` verilirse ad değiştirilemez
/// (toplantılarda verilmiş ad; değişirse kişi ikiye bölünürdü).
private struct PersonForm: View {
    let title: LocalizedStringKey
    let lockedName: String?
    let onSave: @MainActor (String, String, String) -> Void
    let onCancel: @MainActor () -> Void
    @State private var name: String
    @State private var role: String
    @State private var email: String
    @FocusState private var nameFocused: Bool

    init(title: LocalizedStringKey, initialName: String, lockedName: String?, initialRole: String, initialEmail: String, onSave: @escaping @MainActor (String, String, String) -> Void, onCancel: @escaping @MainActor () -> Void) {
        self.title = title
        self.lockedName = lockedName
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
        _role = State(initialValue: initialRole)
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        let canSave: Bool = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                PersonAvatar(name: name.isEmpty ? "?" : name, size: 56)
                Text(title).appFont(size: 28, weight: .regular).tracking(-0.4)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let lockedName {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Ad").appFont(size: 12, weight: .medium).foregroundStyle(Theme.muted)
                        Text(lockedName).appFont(size: 14, weight: .medium)
                        Text("Ad toplantılarda verildi; değiştirmek için toplantının Transkript sekmesini kullan.")
                            .appFont(size: 11, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    field(label: "Ad", prompt: "Örn. Aino Virtanen", text: $name)
                        .focused($nameFocused)
                }
                field(label: "Ünvan ya da kurum", prompt: "Örn. Ürün müdürü, Acme", text: $role)
                field(label: "E-posta", prompt: "aino@ornek.fi", text: $email)
            }
            .padding(18)
            .cardSurface(cornerRadius: 16)
            Text("Ad konuşma tanımaya verilir; bir toplantıda konuşmacıya bu adı verince toplantıları ve görevleri burada toplanır.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Kaydet") { onSave(name, role, email) }
                    .buttonStyle(.pillPrimary)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
                Button("Vazgeç") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(32)
        .frame(maxWidth: 620, alignment: .leading)
        .onAppear { nameFocused = true }
    }

    private func field(label: LocalizedStringKey, prompt: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).appFont(size: 12, weight: .medium).foregroundStyle(Theme.muted)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .appFont(size: 14, weight: .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
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
            .foregroundStyle(personColor(person: hash % DesignTokens.personPalette.count + 1))
            .frame(width: size, height: size)
            .background(Circle().fill(personColor(person: hash % DesignTokens.personPalette.count + 1).opacity(0.15)).background(Circle().fill(Theme.card)))
            .accessibilityHidden(true)
    }
}

/// Kişinin sayfası: başlık (rozet, ad, ünvan, e-posta, sesi; düzenle ve kaldır), özet sayılar, toplantıları ve
/// görevleri. Kaldırma iki adımlıdır (yanlışlıkla tıklanmasın).
private struct PersonDetail: View {
    let person: PersonSummary
    let router: MainWindowRouter
    let onSave: @MainActor (String, String, String) -> Void
    let onRemove: @MainActor () -> Void
    @State private var isEditing: Bool = false
    @State private var confirmRemove: Bool = false

    var body: some View {
        if isEditing {
            PersonForm(
                title: "Kişiyi düzenle", initialName: person.name, lockedName: person.isSaved && person.meetings.isEmpty ? nil : person.name,
                initialRole: person.role, initialEmail: person.email
            ) { (name: String, role: String, email: String) -> Void in
                onSave(name, role, email)
                isEditing = false
            } onCancel: {
                isEditing = false
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    PersonAvatar(name: person.name, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name).appFont(size: 28, weight: .regular).tracking(-0.4)
                        if !person.role.isEmpty {
                            Text(person.role).appFont(size: 14, weight: .regular)
                        }
                        HStack(spacing: 14) {
                            if !person.email.isEmpty, let url = URL(string: "mailto:\(person.email)") {
                                Link(destination: url) {
                                    Label(person.email, systemImage: "envelope")
                                }
                            }
                            Label(person.hasVoiceprint ? "Sesinden tanınıyor" : "Sesi henüz kayıtlı değil", systemImage: person.hasVoiceprint ? "waveform.badge.checkmark" : "waveform")
                                .foregroundStyle(Theme.muted)
                        }
                        .appFont(size: 13, weight: .regular)
                    }
                    Spacer(minLength: 12)
                    if confirmRemove {
                        HStack(spacing: 6) {
                            Text("Kaldırılsın mı?").appFont(size: 12, weight: .medium).foregroundStyle(Theme.muted)
                            Button("Kaldır", role: .destructive) { onRemove() }
                            Button("Vazgeç") { confirmRemove = false }
                        }
                        .controlSize(.small)
                        .transition(.opacity)
                    } else {
                        HStack(spacing: 6) {
                            Button("Düzenle", systemImage: "pencil") { isEditing = true }
                            Button("Kaldır", systemImage: "trash") { confirmRemove = true }
                                .hoverHint("Kişiler'den kaldırır ve sesini unutur; toplantılardaki adı kalır", alignment: .trailing, edge: .bottom)
                        }
                        .controlSize(.small)
                    }
                }
                .animation(.smooth(duration: 0.2), value: confirmRemove)
                HStack(spacing: 12) {
                    stat(value: "\(person.meetings.count)", label: "toplantı")
                    // Konuşması olan kişide en az 1 dk; hiç konuşmayan (elle eklenen) kişide 0.
                    stat(value: String(localized: "\(person.totalSeconds > 0 ? max(1, Int((person.totalSeconds / 60).rounded())) : 0) dk"), label: "konuşma")
                    stat(value: "\(person.tasks.count)", label: "görev")
                }
                if person.meetings.isEmpty {
                    EmptyStatePlaceholder(
                        symbol: "calendar.badge.clock", title: "Henüz toplantı yok",
                        message: "Bir toplantının Transkript sekmesinde konuşmacıya bu adı verince toplantıları, konuşma payı ve görevleri burada görünür."
                    )
                } else {
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

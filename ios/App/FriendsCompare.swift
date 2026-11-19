import SwiftUI

// Friends (0.28): compare timetables (from a friend's page, or a group's), the rides you can share there and home,
// free time together, and meet halfway. The rules are `Compare`, `SharedRides` and `MeetHalfway` (tested); the
// planner's questions are `CompareModel` / `MeetModel`. Follows the phone's light or dark.

struct CompareView: View {
    let key: String
    @StateObject private var model: CompareModel
    @ObservedObject private var store = FriendStore.shared
    @ObservedObject private var tt = FriendTimetables.shared
    @State private var meeting: String?

    init(key: String) {
        self.key = key
        _model = StateObject(wrappedValue: CompareModel(key: key))
    }

    private var title: String {
        if let gid = ChatKey.groupId(key) { return store.group(gid)?.name ?? "Group" }
        return store.book?.friend(key)?.name ?? "Friend"
    }

    private var thisWeek: [CompareDay] { model.days.filter { !Self.nextWeek($0.key) } }
    private var nextWeek: [CompareDay] { model.days.filter { Self.nextWeek($0.key) } }

    static func nextWeek(_ key: String, now: Date = Date()) -> Bool {
        let cal = TimetableDays.calendar
        guard let d = TimetableDays.date(key),
              let monday = cal.dateInterval(of: .weekOfYear, for: now)?.start,
              let next = cal.date(byAdding: .day, value: 7, to: monday) else { return false }
        return d >= next
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s12) {
                CompareHeader(model: model)
                CompareShareNotes(model: model, key: key)
                if !thisWeek.isEmpty { weekSection("This week", thisWeek) }
                if !nextWeek.isEmpty { weekSection("Next week", nextWeek) }
                if model.people.count >= 2 {
                    DSPrimaryButton(title: "Meet halfway", icon: "point.3.connected.trianglepath.dotted") {
                        meeting = Compare.nextShared(model.days, now: Date()) ?? model.days.first?.key
                    }
                    .disabled(model.days.isEmpty)
                }
                footer
            }
            .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
        }
        .background(DS.page.ignoresSafeArea())
        .navigationTitle("Compare · \(title)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task {
            await model.reload()
            await model.autoLoad()
        }
        .onChange(of: tt.seen.count) { _, _ in Task { await model.reload() } }
        .sheet(item: Binding(get: { meeting.map(MeetDay.init) }, set: { meeting = $0?.key })) { d in
            MeetSheet(model: model, startDay: d.key, chatKey: key)
        }
    }

    private func weekSection(_ name: String, _ list: [CompareDay]) -> some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Text(name).font(DS.footnoteStrong).foregroundStyle(DS.secondary).textCase(.uppercase)
                .padding(.horizontal, DS.s4).padding(.top, DS.s8)
                .accessibilityAddTraits(.isHeader)
            ForEach(list) { d in CompareDayCard(model: model, day: d, meet: { meeting = d.key }) }
        }
    }

    private var footer: some View {
        Text("Rides together are looked up on this phone with Transitous, for the next school day you share by itself and for other days when you tap them (at most \(RequestBudget.compare) questions while this is open; \(model.budget.used) so far). Timetables arrive when your friends open Haltewekker.")
            .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.s4)
    }
}

private struct MeetDay: Identifiable {
    let key: String
    var id: String { key }
}

/// Who's compared: everyone's picture and whether they shared.
private struct CompareHeader: View {
    @ObservedObject var model: CompareModel
    @ObservedObject private var store = FriendStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Timetables side by side", sub: "\(model.people.count) people")
            ForEach(model.people) { p in
                FriendRowLabel(name: model.title(p.id), id: p.isMe ? "me" : p.id, picture: p.isMe ? store.myPicture : store.pictures[p.id],
                               detail: status(p)) { EmptyView() }
            }
        }
        .dsPanel()
    }

    private func status(_ p: ComparePerson) -> String {
        if p.isMe {
            if p.timetable == nil { return "Your timetable isn’t set up (Settings › School alarm)" }
            return p.timetable?.src == "week" ? "Your week (same times every week)" : "From your school calendar"
        }
        guard let t = p.timetable else { return "Hasn’t shared a timetable with you yet" }
        let n = t.classes.count
        let start = p.area == nil ? " · no start area yet" : ""
        return "\(n == 1 ? "1 class" : "\(n) classes") in the next two weeks\(start)"
    }
}

/// What's not shared (yours, the group's), with the switch right there.
private struct CompareShareNotes: View {
    @ObservedObject var model: CompareModel
    let key: String
    @ObservedObject private var tt = FriendTimetables.shared
    @ObservedObject private var store = FriendStore.shared

    private var nonFriends: [String] {
        guard let gid = ChatKey.groupId(key), let g = store.group(gid) else { return [] }
        let me = store.myAccount ?? ""
        return g.others(me).filter { !(store.book?.isFriend($0.id) ?? false) }.map { store.name($0.id) }
    }

    var body: some View {
        if !tt.answered || !tt.on {
            VStack(alignment: .leading, spacing: DS.s8) {
                DSNote(icon: "calendar.badge.exclamationmark", tint: DS.accent,
                       text: "Your timetable isn’t shared, so your friends can’t compare with you. They’d see your classes for the next two weeks and the stops near your home (never your address).")
                DSQuietButton(title: "Share my timetable with friends", icon: "calendar", full: true) { tt.setOn(true) }
            }
        }
        if let gid = ChatKey.groupId(key), !nonFriends.isEmpty {
            groupCard(gid)
        }
    }

    @ViewBuilder private func groupCard(_ gid: String) -> some View {
        let names: String = CompareWords.names(nonFriends)
        let on: Bool = tt.groupsOn.contains(gid)
        VStack(alignment: .leading, spacing: DS.s8) {
            Toggle(isOn: Binding(get: { on }, set: { tt.setGroup(gid, $0) })) {
                Text("Share my timetable with this group").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            .tint(DS.accent)
            .frame(minHeight: DS.hit)
            Text(on
                 ? "\(names) (not your friends) see your classes and the stops near your home too, while you’re both in the group."
                 : "Your friends here see it already. \(names) aren’t your friends: they see it only if you turn this on.")
                .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .dsPanel()
    }
}

/// One day: everyone's classes in a line each, the rides there and home together, free time together.
private struct CompareDayCard: View {
    @ObservedObject var model: CompareModel
    let day: CompareDay
    let meet: () -> Void
    @ObservedObject private var store = FriendStore.shared

    private var label: String {
        let d = TimetableDays.short(day.key)
        let today = TimetableDays.key(Date())
        if day.key == today { return "Today · " + d }
        if let t = TimetableDays.date(today), let tomorrow = TimetableDays.calendar.date(byAdding: .day, value: 1, to: t),
           TimetableDays.key(tomorrow) == day.key { return "Tomorrow · " + d }
        return d
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Text(label).font(DS.headline).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
            ForEach(day.people, id: \.id) { p in personRow(p) }
            if day.shared { together }
            NavigationLink(value: FriendsRoute.compareDay(model.key, day.key)) {
                HStack {
                    Text("Every class").font(DS.subStrong)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                }
                .foregroundStyle(DS.accentText)
                .frame(minHeight: DS.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .dsPanel()
    }

    private func personRow(_ p: PersonDay) -> some View {
        let name: String = model.title(p.id)
        let pic: Data? = p.id == model.me ? store.myPicture : store.pictures[p.id]
        return HStack(spacing: DS.s8) {
            FriendAvatar(name: name, id: p.id == model.me ? "me" : p.id, picture: pic, size: 28)
            Text(name).font(DS.subStrong).foregroundStyle(DS.text).lineLimit(1)
            Spacer(minLength: DS.s8)
            Text(CompareWords.day(p)).font(DS.sub).monospacedDigit().foregroundStyle(p.hasSchool ? DS.text : DS.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var together: some View {
        Divider().overlay(DS.divider)
        if let r = model.rides[day.key] {
            CompareRideLines(model: model, day: day, rides: r)
            DSQuietButton(title: "Meet halfway this day", icon: "point.3.connected.trianglepath.dotted", full: true, action: meet)
        } else if model.loading.contains(day.key) {
            HStack(spacing: DS.s8) {
                ProgressView()
                Text("Looking up rides together…").font(DS.sub).foregroundStyle(DS.secondary)
            }
            .frame(minHeight: DS.hit)
        } else {
            DSQuietButton(title: "Find rides together", icon: "tram.fill", full: true) { Task { await model.load(day.key) } }
                .accessibilityHint("Looks up everyone’s way there and home with the planner")
        }
        ForEach(Compare.freeTogether(day), id: \.start) { s in
            Label(CompareWords.free(s, name: model.name), systemImage: "cup.and.saucer.fill")
                .font(DS.sub).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "To school: IC 3512 · 07:41 from Veghel — you, Sam and Lisa · Tom starts 10:45", the same home.
private struct CompareRideLines: View {
    @ObservedObject var model: CompareModel
    let day: CompareDay
    let rides: DayRides

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            block("To school", rides.school, .toSchool, icon: "sunrise.fill")
            block("Home", rides.home, .home, icon: "house.fill")
            if rides.partial {
                Text("Some ways couldn’t be looked up just now.").font(DS.footnote).foregroundStyle(DS.secondary)
            }
        }
    }

    @ViewBuilder private func block(_ title: String, _ list: [SharedRide], _ dir: SharedRides.Direction, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(DS.footnoteStrong).foregroundStyle(DS.secondary)
            if let best = list.first {
                Text(RideWords.headline(best)).font(DS.subStrong).foregroundStyle(DS.text).monospacedDigit()
                Text("With " + RideWords.riders(best, name: model.name)).font(DS.sub).foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                let others: String = missing(best, dir)
                if !others.isEmpty {
                    Text(others).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(list.dropFirst()), id: \.trip) { r in
                    Text("Also: \(RideWords.headline(r)) · \(RideWords.riders(r, name: model.name))")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(dir == .toSchool ? "No bus or train two of you share on the way there." : "No bus or train two of you share on the way home.")
                    .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func missing(_ r: SharedRide, _ dir: SharedRides.Direction) -> String {
        let on = Set(r.ids)
        let lines: [String] = day.people.filter { !on.contains($0.id) }.map { p in
            let hasArea: Bool = model.people.first { $0.id == p.id }?.area != nil
            return RideWords.missing(p, dir, name: model.title(p.id), hasArea: hasArea)
        }
        return lines.joined(separator: " · ")
    }
}

/// A day in full: each person's classes, and the rides.
struct CompareDayView: View {
    let key: String
    let dayKey: String
    @ObservedObject private var store = FriendStore.shared
    @StateObject private var model: CompareModel

    init(key: String, dayKey: String) {
        self.key = key
        self.dayKey = dayKey
        _model = StateObject(wrappedValue: CompareModel(key: key))
    }

    private var day: CompareDay? { model.days.first { $0.key == dayKey } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s12) {
                if let d = day {
                    ForEach(d.people, id: \.id) { p in personCard(p) }
                    if let r = model.rides[d.key] {
                        CompareRideLines(model: model, day: d, rides: r).dsPanel()
                    }
                } else {
                    Text("Nothing for this day.").font(DS.sub).foregroundStyle(DS.secondary)
                }
            }
            .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
        }
        .background(DS.page.ignoresSafeArea())
        .navigationTitle(TimetableDays.short(dayKey))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.reload()
            if day?.shared == true { await model.load(dayKey) }
        }
    }

    private func personCard(_ p: PersonDay) -> some View {
        let name: String = model.title(p.id)
        return VStack(alignment: .leading, spacing: DS.s8) {
            HStack(spacing: DS.s8) {
                FriendAvatar(name: name, id: p.id == model.me ? "me" : p.id,
                             picture: p.id == model.me ? store.myPicture : store.pictures[p.id], size: 32)
                Text(name).font(DS.headline).foregroundStyle(DS.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if !p.known {
                Text("Not shared for this day.").font(DS.sub).foregroundStyle(DS.secondary)
            } else if p.classes.isEmpty {
                Text("No classes.").font(DS.sub).foregroundStyle(DS.secondary)
            } else {
                ForEach(Array(p.classes.enumerated()), id: \.offset) { _, c in
                    Text(CompareWords.lesson(c)).font(DS.sub).monospacedDigit().foregroundStyle(DS.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanel()
    }
}

// MARK: meet halfway

/// Pick a day and a time (each first class, or be there by), and see a bus or train all of you can be on.
struct MeetSheet: View {
    @ObservedObject var model: CompareModel
    let startDay: String
    let chatKey: String
    @StateObject private var meet = MeetModel()
    @Environment(\.dismiss) private var dismiss
    @State private var dayKey = ""
    @State private var useTime = false
    @State private var time = Date()
    @State private var card: TripCard?

    private var day: CompareDay? { model.days.first { $0.key == dayKey } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    Text("A bus or train all of you can be on to school: each of you gets on at your own stop, or you meet at a station first. Looked up now on this phone (a few questions to Transitous).")
                        .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    choices
                    DSPrimaryButton(title: meet.busy ? "Looking…" : "Find a way together", icon: "magnifyingglass") { search() }
                        .disabled(meet.busy || day == nil)
                    results
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Meet halfway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .followsSystemScheme()
        .onAppear {
            if dayKey.isEmpty { dayKey = startDay }
            time = defaultTime()
        }
        .sheet(item: Binding(get: { card.map(IdentifiedCard.init) }, set: { card = $0?.card })) { c in
            SendTripSheet(card: c.card, preselect: [chatKey])
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            Picker("Day", selection: $dayKey) {
                ForEach(model.days) { d in Text(TimetableDays.short(d.key)).tag(d.key) }
            }
            .pickerStyle(.menu)
            .frame(minHeight: DS.hit)
            Toggle(isOn: $useTime) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick a time").font(DS.bodyStrong).foregroundStyle(DS.text)
                    Text(useTime ? "Everyone there by this time." : "Each of you there for your own first class.")
                        .font(DS.footnote).foregroundStyle(DS.secondary)
                }
            }
            .tint(DS.accent)
            if useTime {
                DatePicker("Be there by", selection: $time, displayedComponents: .hourAndMinute)
                    .frame(minHeight: DS.hit)
            }
        }
        .dsPanel()
    }

    @ViewBuilder private var results: some View {
        if let n = meet.note {
            DSNote(icon: "info.circle.fill", tint: DS.accent, text: n)
        }
        ForEach(meet.plans) { p in MeetPlanCard(plan: p, model: model, meet: meet, send: { card = makeCard(p) }) }
        if meet.searched {
            Text("\(meet.asked) of at most \(RequestBudget.meet) questions to the planner for this search.")
                .font(DS.footnote).foregroundStyle(DS.secondary)
        }
    }

    private func defaultTime() -> Date {
        let starts: [Date] = day?.atSchool.compactMap(\.first) ?? []
        if let s = starts.min() { return s.addingTimeInterval(-10 * 60) }
        return TimetableDays.calendar.date(bySettingHour: 8, minute: 30, second: 0, of: TimetableDays.date(dayKey) ?? Date()) ?? Date()
    }

    private func search() {
        guard let d = day else { return }
        var by: Date?
        if useTime, let base = TimetableDays.date(d.key) {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            by = TimetableDays.calendar.date(bySettingHour: c.hour ?? 8, minute: c.minute ?? 30, second: 0, of: base)
        }
        let people: [ComparePerson] = model.people
        Task { await meet.search(people: people, day: d, by: by) }
    }

    /// The card for the chat: in a friend's chat their own way (so "Take this trip" plans it for them); in a group
    /// yours (each of them takes it from where they are).
    private func makeCard(_ p: MeetPlan) -> TripCard? {
        let me = model.me
        let note: String = MeetWords.note(p, name: model.name, me: me)
        let who: String = ChatKey.isGroup(chatKey) || p.ways[chatKey] == nil ? me : chatKey
        let id: String = p.ways[who] != nil ? who : (p.ways.keys.sorted().first ?? me)
        guard let w = p.ways[id], let to = meet.schools[id] else { return nil }
        return MeetHalfway.card(w, to: to, by: meet.bounds[id], note: note)
    }
}

/// One way together: the shared ride, then each person's way (or that it doesn't fit them).
private struct MeetPlanCard: View {
    let plan: MeetPlan
    @ObservedObject var model: CompareModel
    @ObservedObject var meet: MeetModel
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Text(MeetWords.title(plan)).font(DS.headline).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.people) { p in row(p.id) }
            DSQuietButton(title: "Send to \(chatName)", icon: "paperplane", full: true, action: send)
                .accessibilityHint("Sends this way as a trip card to the chat")
        }
        .dsPanel()
    }

    private var chatName: String {
        if let gid = ChatKey.groupId(model.key) { return FriendStore.shared.group(gid)?.name ?? "the group" }
        return FriendStore.shared.book?.friend(model.key)?.name ?? "your friend"
    }

    @ViewBuilder private func row(_ id: String) -> some View {
        let name: String = model.title(id)
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(DS.subStrong).foregroundStyle(DS.text)
            if let w = plan.ways[id] {
                Text(MeetWords.way(w)).font(DS.sub).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                if let by = meet.bounds[id] {
                    let spare: Int = max(0, Int(by.timeIntervalSince(w.end) / 60))
                    Text("Needs to be there by \(TimetableDays.hhmm(by))" + (spare > 0 ? " · \(spare) min to spare" : ""))
                        .font(DS.footnote).foregroundStyle(DS.secondary)
                }
            } else {
                Text("Can’t get onto it in time: their own way is quicker.").font(DS.sub).foregroundStyle(DS.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: in Friends

/// Friends › Your timetable: the switch for everyone, and what it shares.
struct MyTimetableCard: View {
    @ObservedObject private var tt = FriendTimetables.shared
    @ObservedObject private var store = FriendStore.shared
    let explain: () -> Void

    private var on: Binding<Bool> {
        Binding(get: { tt.answered && tt.on }, set: { tt.setOn($0) })
    }

    private var status: String {
        if !tt.answered { return "Off until you say yes. Friends would see your classes for the next two weeks to compare." }
        if !tt.on { return "Off: no friend sees your timetable." }
        if let at = tt.sentAt {
            let n = tt.sentCount
            return "Shared with \(n == 1 ? "1 person" : "\(n) people") · last sent \(FriendDates.day(at)) \(Fmt.hhmm(at)). It follows your timetable, at most every few hours."
        }
        return "Shared with friends once your timetable is read (Settings › School alarm)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            DSHeader(title: "Your timetable")
            Toggle(isOn: on) {
                Text("Share my timetable").font(DS.bodyStrong).foregroundStyle(DS.text)
            }
            .tint(DS.accent)
            .frame(minHeight: DS.hit)
            Text(status).font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: explain) {
                Text("What friends see").font(DS.subStrong).foregroundStyle(DS.accentText)
                    .frame(minHeight: DS.hit).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .dsPanel()
    }
}

/// The one-time screen: what friends see of your timetable, with the switch right there.
struct TimetableConsentSheet: View {
    @ObservedObject private var tt = FriendTimetables.shared
    @Environment(\.dismiss) private var dismiss
    @State private var share = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    Image(systemName: "calendar")
                        .font(.title2.weight(.semibold)).foregroundStyle(DS.onAccent)
                        .frame(width: 56, height: 56).background(DS.accent, in: Circle())
                        .accessibilityHidden(true)
                    Text("Compare timetables with friends?").font(DS.title).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                    point("calendar", "Your classes for the next two weeks: the day, when each starts and ends, its name and room. From the school calendar you picked, or your week.")
                    point("mappin.and.ellipse", "Where your trips start and end, roughly: the stops and the station nearest your home, and your school. Never your home address.")
                    point("tram.fill", "So you can see the days you can ride together, there and home, and meet halfway. All worked out on the phones.")
                    point("lock.fill", "Locked end to end for each friend: nobody else can read it, not even the Haltewekker relay. In a group, people who aren’t your friends see it only if you turn it on for that group.")
                    point("person.crop.circle.badge.checkmark", "Turn it off for one friend on their page, or for everyone in Friends, at any time.")
                    Toggle(isOn: $share) {
                        Text("Share my timetable with friends").font(DS.bodyStrong).foregroundStyle(DS.text)
                    }
                    .tint(DS.accent)
                    .frame(minHeight: DS.hit)
                    .padding(.horizontal, DS.s16).padding(.vertical, DS.s4)
                    .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                    DSPrimaryButton(title: "Done") {
                        tt.answer(share: share)
                        dismiss()
                    }
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Your timetable")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .followsSystemScheme()
        .interactiveDismissDisabled(!tt.answered)
        .onAppear { share = tt.answered ? tt.on : true }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.s12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(DS.accentText)
                .frame(width: 22).accessibilityHidden(true)
            Text(text).font(DS.sub).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// On a friend's or a group's page: open the comparison.
struct CompareButton: View {
    let key: String
    var body: some View {
        NavigationLink(value: FriendsRoute.compare(key)) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.body.weight(.semibold))
                Text("Compare timetables").font(DS.bodyStrong)
            }
            .foregroundStyle(DS.accentText)
            .frame(maxWidth: .infinity, minHeight: DS.cta)
            .background(DS.surface3, in: Capsule())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityHint("Classes side by side this week and next, rides together and meet halfway")
    }
}

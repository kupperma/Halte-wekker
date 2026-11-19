import PhotosUI
import SwiftUI

// Friends (0.27): groups: making one from your friends (a name and a picture), who's in it, and (for the one who runs
// it) adding, removing and renaming; leaving for anyone.

/// Pick friends (each with a tick).
struct FriendPicker: View {
    let friends: [Friend]
    @Binding var picked: Set<String>
    var max = GroupRoster.maxMembers - 1
    @ObservedObject private var store = FriendStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s4) {
            ForEach(friends) { f in
                row(f)
                if f.id != friends.last?.id { Divider().overlay(DS.divider) }
            }
        }
    }

    private func row(_ f: Friend) -> some View {
        let on: Bool = picked.contains(f.id)
        let full: Bool = !on && picked.count >= max
        return Button {
            if on { picked.remove(f.id) } else if !full { picked.insert(f.id) }
        } label: {
            FriendRowLabel(name: f.name, id: f.id, picture: store.pictures[f.id], detail: full ? "The group is full" : "") {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? DS.accentText : DS.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(full)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// A group's round picture, or its initials.
struct GroupPictureButton: View {
    let name: String
    let id: String
    @Binding var picture: Data?
    @State private var item: PhotosPickerItem?
    @State private var loading = false

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                FriendAvatar(name: name.isEmpty ? "?" : name, id: "g-\(id)", picture: picture, size: 88)
                Image(systemName: picture == nil ? "camera.fill" : "pencil")
                    .font(.footnote.weight(.bold)).foregroundStyle(DS.onAccent)
                    .frame(width: 28, height: 28)
                    .background(DS.accent, in: Circle())
                    .overlay(Circle().stroke(DS.surface, lineWidth: 2))
            }
            .overlay { if loading { ProgressView() } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(picture == nil ? "Choose a picture for the group" : "Change the group’s picture")
        .onChange(of: item) { _, new in
            guard let new else { return }
            loading = true
            Task {
                let data = try? await new.loadTransferable(type: Data.self)
                let small = data.flatMap { FriendPictureMaker.make(from: $0) }
                await MainActor.run {
                    if let small { picture = small }
                    loading = false
                }
            }
        }
    }
}

/// A new group: a name, a picture if you like, and your friends in it.
struct NewGroupSheet: View {
    var made: (String) -> Void = { _ in }
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picture: Data?
    @State private var picked: Set<String> = []
    @State private var busy = false
    @State private var failed = false
    @State private var tempId = GroupBook.newId()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    VStack(spacing: DS.s12) {
                        GroupPictureButton(name: name, id: tempId, picture: $picture)
                        TextField("Group name", text: $name)
                            .font(DS.body)
                            .submitLabel(.done)
                            .padding(.horizontal, DS.s16)
                            .frame(minHeight: 52)
                            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                            .accessibilityLabel("Group name")
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: DS.s8) {
                        DSHeader(title: "Who’s in it", sub: picked.isEmpty ? nil : "\(picked.count + 1) with you")
                        FriendPicker(friends: store.book?.sortedFriends ?? [], picked: $picked)
                    }
                    .dsPanel()
                    Text("You run the group: you add and remove people and change its name and picture. Everyone in it sees the others’ names and pictures, and each message is locked for every member on its own.")
                        .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                    if failed {
                        DSNote(icon: "exclamationmark.triangle.fill", text: "Couldn’t make the group. Pick at least one friend.")
                    }
                }
                .padding(.horizontal, DS.s16).padding(.top, DS.s8).padding(.bottom, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                DSPrimaryButton(title: busy ? "Making it…" : "Make the group", icon: "person.3.fill") { create() }
                    .disabled(busy || picked.isEmpty)
                    .opacity(picked.isEmpty ? 0.5 : 1)
                    .padding(.horizontal, DS.s16).padding(.vertical, DS.s8)
                    .background(DS.page.ignoresSafeArea(edges: .bottom))
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .followsSystemScheme()
    }

    private func create() {
        busy = true
        failed = false
        let ids: [String] = Array(picked).sorted()
        let n: String = name
        let p: Data? = picture
        Task {
            let id = await store.createGroup(name: n, friends: ids, picture: p)
            busy = false
            if let id {
                dismiss()
                made(id)
            } else {
                failed = true
            }
        }
    }
}

/// A group: its picture and name, who's in it, and what you may change.
struct GroupInfoView: View {
    let id: String
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var picture: Data?
    @State private var asking = false
    @State private var askingDelete = false
    @State private var removing: GroupMember?

    private var group: FriendGroup? { store.group(id) }
    private var me: String { store.myAccount ?? "" }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.s16) {
                if let g = group {
                    header(g)
                    if g.isIn { CompareButton(key: ChatKey.group(g.id)) }
                    if g.out == .removed {
                        DSNote(icon: "person.crop.circle.badge.xmark", text: "You were taken off this group. Its chat stays here to read.")
                    }
                    members(g)
                    actions(g)
                } else {
                    Text("This group isn’t on this phone any more.").font(DS.sub).foregroundStyle(DS.secondary)
                }
            }
            .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            .frame(maxWidth: .infinity)
        }
        .background(DS.page.ignoresSafeArea())
        .navigationTitle(group?.name ?? "Group")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { picture = store.groupPictures[id] }
        .onChange(of: picture) { _, new in
            guard new != store.groupPictures[id], group?.isAdmin(me) == true else { return }
            Task { await store.setGroupPicture(id, new) }
        }
        .sheet(isPresented: $adding) { AddToGroupSheet(id: id) }
        .alert("Group name", isPresented: $renaming) {
            TextField("Group name", text: $newName)
            Button("Save") { Task { await store.renameGroup(id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Leave \(group?.name ?? "the group")?", isPresented: $asking, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await store.leaveGroup(id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone in it is told. You can’t come back to this group: someone would make a new one.")
        }
        .confirmationDialog("Delete this chat?", isPresented: $askingDelete, titleVisibility: .visible) {
            Button("Delete the chat", role: .destructive) {
                store.forgetGroup(id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from the group", role: .destructive) {
                if let m = removing { Task { await store.removeFromGroup(id, member: m.id) } }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        }
    }

    @ViewBuilder private func header(_ g: FriendGroup) -> some View {
        if g.isAdmin(me) {
            GroupPictureButton(name: g.name, id: g.id, picture: $picture)
        } else {
            FriendAvatar(name: g.name, id: "g-\(g.id)", picture: store.groupPictures[g.id], size: 88)
        }
        Text(g.name).font(DS.title).foregroundStyle(DS.text).multilineTextAlignment(.center)
        Text("\(g.roster.members.count) people · run by \(store.name(g.roster.admin))").font(DS.sub).foregroundStyle(DS.secondary)
    }

    private func members(_ g: FriendGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.s4) {
            DSHeader(title: "Who’s in it", sub: "\(g.roster.members.count)")
            ForEach(g.roster.members) { m in
                memberRow(m, g)
                if m.id != g.roster.members.last?.id { Divider().overlay(DS.divider) }
            }
        }
        .dsPanel()
    }

    private func memberRow(_ m: GroupMember, _ g: FriendGroup) -> some View {
        let isMe: Bool = m.id == me
        let friend: Bool = store.book?.isFriend(m.id) ?? false
        let role: String = m.id == g.roster.admin ? "Runs the group" : ""
        let detail: String = [isMe ? "You" : (friend ? "Your friend" : "In this group"), role].filter { !$0.isEmpty }.joined(separator: " · ")
        let name: String = isMe ? (store.myName.isEmpty ? "You" : store.myName) : m.name
        let pic: Data? = isMe ? store.myPicture : store.pictures[m.id]
        return FriendRowLabel(name: name, id: m.id, picture: pic, detail: detail) {
            if g.isAdmin(me), !isMe {
                Button { removing = m } label: {
                    Image(systemName: "minus.circle").font(.title3).foregroundStyle(DS.warning)
                        .frame(minWidth: DS.hit, minHeight: DS.hit)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(m.name)")
            }
        }
    }

    @ViewBuilder private func actions(_ g: FriendGroup) -> some View {
        VStack(spacing: DS.s8) {
            if g.isAdmin(me) {
                if g.roster.members.count < GroupRoster.maxMembers {
                    DSQuietButton(title: "Add friends", icon: "person.badge.plus", full: true) { adding = true }
                }
                DSQuietButton(title: "Change the name", icon: "pencil", full: true) { newName = g.name; renaming = true }
            }
            if g.isIn {
                DSQuietButton(title: "Leave the group", icon: "rectangle.portrait.and.arrow.right", full: true) { asking = true }
            } else {
                DSQuietButton(title: "Delete the chat", icon: "trash", full: true) { askingDelete = true }
            }
            Text(g.isAdmin(me) ? "Only friends of yours can be added. If you leave, \(nextAdmin(g)) runs the group."
                               : "Only \(store.name(g.roster.admin)) can add or remove people.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nextAdmin(_ g: FriendGroup) -> String {
        g.roster.members.first { $0.id != me }.map(\.name) ?? "nobody"
    }
}

/// (the one who runs it) More friends into a group.
struct AddToGroupSheet: View {
    let id: String
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []

    private var candidates: [Friend] {
        let g = store.group(id)
        return (store.book?.sortedFriends ?? []).filter { !(g?.roster.has($0.id) ?? false) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s12) {
                    if candidates.isEmpty {
                        Text("All your friends are in this group already.").font(DS.sub).foregroundStyle(DS.secondary)
                    } else {
                        FriendPicker(friends: candidates, picked: $picked, max: GroupRoster.maxMembers - (store.group(id)?.roster.members.count ?? 1))
                            .dsPanel()
                    }
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s16)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Add friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let ids: [String] = Array(picked).sorted()
                        Task { await store.addToGroup(id, friends: ids) }
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
        .tint(DS.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .followsSystemScheme()
    }
}

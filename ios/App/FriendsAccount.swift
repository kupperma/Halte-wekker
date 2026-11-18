import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Friends (0.25): making the account (name and picture), the backup code, restoring, and changing your profile.

/// Friends › Make my friend code: your name and picture, then the backup code, said once and clearly.
struct FriendCreateSheet: View {
    /// After the account is made (e.g. to send the request that opened this).
    var then: (() -> Void)? = nil
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picture: Data?
    @State private var busy = false
    @State private var error: String?
    @State private var made = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.s16) {
                    if made { BackupCodeView(fresh: true) } else { form }
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle(made ? "Your backup code" : "Your friend code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { if !made { Button("Cancel") { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    if made { Button("Done") { dismiss(); then?() } }
                }
            }
            .interactiveDismissDisabled(made || busy)
        }
        .tint(DS.accentText)
    }

    private var form: some View {
        VStack(spacing: DS.s16) {
            FriendProfileEditor(name: $name, picture: $picture)
            Text("Friends see this name and picture. Nobody else does: not even the relay that carries the boxes.")
                .font(DS.sub).foregroundStyle(DS.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let error { DSNote(icon: "wifi.exclamationmark", text: error) }
            DSPrimaryButton(title: busy ? "Making your code…" : "Make my friend code", icon: "person.crop.circle.badge.plus") { make() }
                .disabled(busy || FriendNames.clean(name).isEmpty)
                .opacity(FriendNames.clean(name).isEmpty ? 0.5 : 1)
        }
    }

    private func make() {
        busy = true
        error = nil
        Task {
            do {
                try await store.create(name: name)
                if let picture { await store.setPicture(picture) }
                made = true
            } catch {
                self.error = "Couldn’t reach the Haltewekker relay. Check your connection and try again."
            }
            busy = false
        }
    }
}

/// The 12 words, and what they're for.
struct BackupCodeView: View {
    /// Just made: said once, clearly.
    var fresh = false
    @ObservedObject private var store = FriendStore.shared
    @State private var copied = false
    private let columns = [GridItem(.flexible(), spacing: DS.s8), GridItem(.flexible(), spacing: DS.s8)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            if fresh {
                Text("Write these 12 words down")
                    .font(DS.title).foregroundStyle(DS.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("They are your backup code. On a new phone they bring back your friends account and your friend list. Without them, a new phone means adding your friends again.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            if let words = store.backupWords {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.s8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        HStack(spacing: 6) {
                            Text("\(i + 1)").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                                .frame(minWidth: 20, alignment: .trailing)
                            Text(w).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(DS.text)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, DS.s12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(DS.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Word \(i + 1): \(w)")
                    }
                }
                .padding(DS.s12)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
                DSQuietButton(title: copied ? "Copied for 2 minutes" : "Copy the words", icon: "doc.on.doc", full: true) {
                    copy(words)
                }
            }
            DSNote(icon: "lock.fill", text: "Keep them private: anyone with these words can be you to your friends. Using them on another phone signs this one out.")
        }
    }

    private func copy(_ words: [String]) {
        // only on this phone, and gone again after two minutes
        UIPasteboard.general.setItems([[UTType.plainText.identifier: words.joined(separator: " ")]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        copied = true
    }
}

/// Friends › Restore from a backup code: the account comes to this phone (and leaves the old one).
struct FriendRestoreSheet: View {
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done: Bool?

    private var words: [String] { FriendWords.words(in: text) }
    private var valid: Bool { FriendWords.decode(words) != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s16) {
                    if let done { result(done) } else { form }
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Restore friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { if done == nil { Button("Cancel") { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { if done != nil { Button("Done") { dismiss() } } }
            }
        }
        .tint(DS.accentText)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.s16) {
            Text("Type your 12 words, in order. The first four letters of each are enough.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            TextField("abandon amount liar …", text: $text, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)
                .padding(DS.s12)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                .accessibilityLabel("Your 12 words")
            Text(status).font(DS.footnote).foregroundStyle(valid ? DS.accentText : DS.secondary)
            TextField("Your name (if no friend list is found)", text: $name)
                .font(DS.body)
                .padding(.horizontal, DS.s16).frame(minHeight: 52)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
            DSNote(icon: "iphone.and.arrow.forward", text: "Your friends account moves to this phone. The phone it was on is signed out of Friends the next time it checks in.")
            if let error { DSNote(icon: "exclamationmark.triangle.fill", text: error) }
            DSPrimaryButton(title: busy ? "Restoring…" : "Restore", icon: "arrow.counterclockwise") { restore() }
                .disabled(!valid || busy)
                .opacity(valid ? 1 : 0.5)
        }
    }

    private var status: String {
        let n = words.count
        if n < FriendWords.count { return "\(n) of \(FriendWords.count) words" }
        if n > FriendWords.count { return "That’s \(n) words: the code has \(FriendWords.count)." }
        return valid ? "The code checks out." : "One of the words isn’t right: check each one."
    }

    private func result(_ found: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.s12) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(DS.accentText).accessibilityHidden(true)
            Text("Friends restored").font(DS.title).foregroundStyle(DS.text)
            Text(found ? "Your friend list is back. Friends see you as before."
                       : "Your account is back, but no friend list was kept for it: add your friends again.")
                .font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func restore() {
        busy = true
        error = nil
        Task {
            do {
                done = try await store.restore(words: words, name: name.isEmpty ? "Me" : name)
            } catch FriendStore.RestoreError.badCode {
                error = "That code doesn’t check out. Check each word."
            } catch {
                self.error = "Couldn’t reach the Haltewekker relay. Check your connection and try again."
            }
            busy = false
        }
    }
}

/// Friends › Your name and picture.
struct FriendProfileSheet: View {
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picture: Data?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.s16) {
                    FriendProfileEditor(name: $name, picture: $picture)
                    Text("Your friends get the new name and picture the next time their app checks in.")
                        .font(DS.sub).foregroundStyle(DS.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("Name and picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(FriendNames.clean(name).isEmpty)
                }
            }
        }
        .tint(DS.accentText)
        .onAppear {
            name = store.book?.myName ?? ""
            picture = store.myPicture
        }
    }

    private func save() {
        let n = name, p = picture, changed = p != store.myPicture
        dismiss()
        Task {
            await store.rename(n)
            if changed { await store.setPicture(p) }
        }
    }
}

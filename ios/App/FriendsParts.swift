import PhotosUI
import SwiftUI
import UIKit

// Friends (0.25): the small shared parts: a person's round picture (or initials on a colour), and making a picture
// from Photos small enough to send.

/// A round picture, or the initials on a colour picked by the account (the same colour on every phone).
struct FriendAvatar: View {
    let name: String
    var id: String = ""
    var picture: Data? = nil
    var size: CGFloat = 44

    private static let colours: [Color] = [DS.accent, DS.train, DS.sprinter, DS.bus, DS.tram, DS.ferry]

    private var colour: Color {
        let n = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.colours[n % Self.colours.count]
    }

    var body: some View {
        Group {
            if let picture, let img = UIImage(data: picture) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    colour
                    Text(FriendNames.initials(name))
                        .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

enum FriendPictureMaker {
    /// A square from the middle, 256 px, as a JPEG under `FriendPicture.maxBytes` (lower quality until it fits).
    static func make(from data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let side: CGFloat = 256
        let s = img.size
        guard s.width > 0, s.height > 0 else { return nil }
        let scale = side / min(s.width, s.height)
        let drawn = CGSize(width: s.width * scale, height: s.height * scale)
        let origin = CGPoint(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            img.draw(in: CGRect(origin: origin, size: drawn))
        }
        for q in [0.8, 0.65, 0.5, 0.35] as [CGFloat] {
            if let j = square.jpegData(compressionQuality: q), j.count <= FriendPicture.maxBytes { return j }
        }
        return nil
    }
}

/// Your name and picture: pick a picture from Photos (cropped square), type a name.
struct FriendProfileEditor: View {
    @Binding var name: String
    @Binding var picture: Data?
    @State private var item: PhotosPickerItem?
    @State private var loading = false

    var body: some View {
        VStack(spacing: DS.s16) {
            PhotosPicker(selection: $item, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    FriendAvatar(name: name.isEmpty ? "?" : name, id: "me", picture: picture, size: 96)
                    Image(systemName: picture == nil ? "camera.fill" : "pencil")
                        .font(.footnote.weight(.bold)).foregroundStyle(DS.onAccent)
                        .frame(width: 30, height: 30)
                        .background(DS.accent, in: Circle())
                        .overlay(Circle().stroke(DS.surface, lineWidth: 2))
                }
                .overlay { if loading { ProgressView() } }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(picture == nil ? "Choose a profile picture" : "Change your profile picture")
            if picture != nil {
                Button("Remove the picture") { picture = nil; item = nil }
                    .font(DS.subStrong).foregroundStyle(DS.accentText)
                    .frame(minHeight: DS.hit)
            }
            TextField("Your name", text: $name)
                .font(DS.body)
                .textContentType(.givenName)
                .submitLabel(.done)
                .padding(.horizontal, DS.s16)
                .frame(minHeight: 52)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
                .accessibilityLabel("Your name")
        }
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

/// A card's row: the picture, a name and a line under it, and whatever goes on the right.
struct FriendRowLabel<Trailing: View>: View {
    let name: String
    let id: String
    let picture: Data?
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DS.s12) {
            FriendAvatar(name: name, id: id, picture: picture)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(2)
                    // (0.30.1) the test friend, wherever it shows
                    if TestFriendBot.shared.isBot(id) { TestFriendTag() }
                }
                Text(detail).font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DS.s8)
            trailing()
        }
        .padding(.vertical, DS.s8)
    }
}

/// "18 Nov"
enum FriendDates {
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: d)
    }
}

/// A small count on the Friends button (requests waiting).
struct FriendsBadge: View {
    let count: Int
    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.caption2.weight(.bold)).monospacedDigit()
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(DS.warning, in: Capsule())
            .accessibilityHidden(true)
    }
}

import SwiftUI

// The new look's shared parts for the trip screens (0.20, phase 2): Fastest trip, the ride, the alarm, the change and
// arrival, and the detail pages. Only the tokens in Design.swift.

/// Hold to confirm, so a sleepy tap doesn't end things: it fills with the accent while you hold it, the label turning
/// white as the fill passes under it. With VoiceOver: double-tap and hold, or its action (through `confirm`'s question
/// when there is one).
struct DSHoldButton: View {
    let title: String
    var seconds: Double = 1.0
    var icon: String? = nil
    var fill: Color = DS.surface3
    /// VoiceOver's action asks this first ("End this trip?"), with `confirmTitle` as the button; nil: it acts at once.
    var confirm: String? = nil
    var confirmTitle = "End"
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var asking = false

    private var actionName: String { title.hasPrefix("Hold to ") ? String(title.dropFirst(8)).capitalizedFirst : title }

    private func label(_ color: Color) -> some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.body.weight(.semibold)) }
            Text(title).font(DS.bodyStrong).lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.center)
        }
        .foregroundStyle(color)
        .padding(.horizontal, DS.s16)
        .frame(maxWidth: .infinity, minHeight: DS.cta)
    }

    var body: some View {
        label(DS.text)
            .background(fill)
            // the accent fills from the left; over it the same label in white, cut to the fill
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        DS.accent
                        label(DS.onAccent).frame(width: g.size.width)
                    }
                    .frame(width: g.size.width * progress, alignment: .leading)
                    .clipped()
                }
                .allowsHitTesting(false)
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DS.divider, lineWidth: 1))
            .scaleEffect(progress > 0 ? 0.98 : 1)
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: seconds, perform: { progress = 0; action() }, onPressingChanged: { p in
                withAnimation(p ? .linear(duration: seconds) : DS.quick) { progress = p ? 1 : 0 }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double-tap and hold for a second, or swipe up or down to \(actionName.lowercased()).")
            .accessibilityAction(named: actionName) { if confirm != nil { asking = true } else { action() } }
            .confirmationDialog(confirm ?? title, isPresented: $asking, titleVisibility: .visible) {
                Button(confirmTitle, role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            }
    }
}

/// A quiet button: a capsule in the third surface, accent text, 44 pt high.
struct DSQuietButton: View {
    let title: String
    var icon: String? = nil
    var full = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.subheadline.weight(.semibold)) }
                Text(title).font(DS.subStrong).lineLimit(2).minimumScaleFactor(0.8)
            }
            .foregroundStyle(DS.accentText)
            .padding(.horizontal, 14)
            .frame(maxWidth: full ? .infinity : nil, minHeight: DS.hit)
            .background(DS.surface3, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(DSPressStyle())
    }
}

/// A heading inside a card, with a quiet note on the right.
struct DSHeader: View {
    let title: String
    var sub: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(DS.headline).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let sub { Text(sub).font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary).multilineTextAlignment(.trailing) }
        }
    }
}

/// A note in a soft wash of its colour: a tight change, a hurry, a late bus.
struct DSNote: View {
    let icon: String
    var tint: Color = DS.warning
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(DS.sub).foregroundStyle(DS.text).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.inner(DS.cardRadius, padding: DS.s8), style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A small number with what it is under it ("2.4 km", "to go").
struct DSStat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A speed or steadiness rank (S to C) as a small rounded square in its colour.
struct DSGrade: View {
    let grade: String?
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            if let g = grade {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(RatingStyle.fill(g))
                Text(g).font(.system(size: size * 0.55, weight: .bold, design: .rounded)).foregroundStyle(RatingStyle.ink(g))
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).stroke(DS.divider, lineWidth: 1.5)
                Text("–").font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(DS.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(grade.map { "\($0) rank" } ?? "No rank")
    }
}

/// How busy NS expects a train: three people, filled up to the level, and the word.
struct DSCrowd: View {
    let level: Int
    var words = true
    var body: some View {
        let l = min(3, max(0, level))
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(1...3, id: \.self) { i in
                    Image(systemName: "person.fill").font(.caption2.weight(.bold))
                        .foregroundStyle(i <= l ? (l >= 2 ? DS.warning : DS.accentText) : DS.divider)
                }
            }
            if words { Text(Self.word(l)).font(DS.footnoteStrong).foregroundStyle(DS.text) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.word(l))
    }
    static func word(_ l: Int) -> String { ["Not known", "Quiet", "Busy", "Very busy"][min(3, max(0, l))] }
}

/// What you're listening to: the cover, the song and the app.
struct DSSongCard: View {
    let song: Song
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = song.image { Image(uiImage: img).resizable().scaledToFill() }
                else if let u = song.artURL {
                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { DS.surface3 }
                } else { ZStack { DS.surface3; Image(systemName: "music.note").font(.title3).foregroundStyle(DS.accentText) } }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: DS.inner(DS.cardRadiusSmall, padding: DS.s12), style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(song.playing ? "Now playing" : "Paused") · \(song.app)").font(DS.footnote).foregroundStyle(DS.secondary).lineLimit(1)
                Text(song.title).font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(1)
                if !song.artist.isEmpty { Text(song.artist).font(DS.sub).foregroundStyle(DS.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Image(systemName: song.playing ? "waveform" : "pause.fill").font(.body.weight(.semibold)).foregroundStyle(DS.accentText)
                .symbolEffect(.variableColor.iterative, isActive: song.playing)
                .accessibilityHidden(true)
        }
        .padding(DS.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.cardRadiusSmall, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(song.playing ? "Now playing" : "Paused"): \(song.title)\(song.artist.isEmpty ? "" : " by \(song.artist)")")
    }
}

/// A round 44 pt button floating over a map or a page (back, close).
struct DSRoundButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.bold)).foregroundStyle(DS.text)
                .frame(width: DS.hit, height: DS.hit)
                .background(DS.surface, in: Circle())
                .dsFloat()
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(label)
    }
}

extension View {
    /// A card on a page (not over the map): the surface and the radius, no shadow.
    func dsPanel(radius: CGFloat = DS.cardRadius, padding: CGFloat = DS.s16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

import SwiftUI

// Listening now (relay 2026-11-27): Settings › Friends' rows for sharing what you listen to, and the strip on a
// travelling friend's page ("LISTENING NOW", the song, "💬 Message", "🎧 Listen too").

/// Settings › Friends: "Share what I'm listening to" (off by default), where it comes from, and who sees it.
struct MusicShareSection: View {
    @ObservedObject private var m = MusicShareStore.shared

    private var on: Binding<Bool> { Binding(get: { m.on }, set: { m.setOn($0) }) }

    var body: some View {
        Section {
            Toggle(isOn: on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share what I’m listening to")
                    Text("Only while you travel · song and artist only").font(DS.footnote).foregroundStyle(DS.secondary)
                }
            }
            .tint(DS.accent)
            .settingsAnchor("friends.music")
            if m.on { rows }
        } header: {
            Text("Listening now")
        } footer: {
            Text("While a trip runs or a live link is on: the song playing now, its artist and app, and its cover. Never what you listened to before, and nothing when you pause.")
        }
    }

    @ViewBuilder private var rows: some View {
        Picker("From", selection: $m.from) {
            ForEach(MusicFrom.allCases) { f in Text(f.title).tag(f) }
        }
        if m.from.viaLastfm {
            TextField("Last.fm username", text: $m.lastfmUser)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.username)
            Text(m.from == .spotify
                 ? "Connect Spotify to Last.fm once (last.fm › Settings › Applications › Spotify scrobbling); Haltewekker then reads what Last.fm says is playing."
                 : "Any app that scrobbles to your Last.fm account.")
                .font(DS.footnote).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
        } else if !m.appleAllowed {
            Text("Let Haltewekker see Apple Music: iPhone Settings › Apps › Haltewekker › Media & Apple Music.")
                .font(DS.footnote).foregroundStyle(DS.warning).fixedSize(horizontal: false, vertical: true)
        }
        Picker("Who sees it", selection: $m.who) {
            ForEach(MusicAudience.allCases) { a in Text(a.title).tag(a) }
        }
        Button(m.checking ? "Checking…" : "Check what’s playing") { m.checkNow() }
            .disabled(m.checking)
        if let p = m.problem {
            Text(p).font(DS.footnote).foregroundStyle(DS.warning).fixedSize(horizontal: false, vertical: true)
        } else if let s = m.current {
            Label(s.artist.isEmpty ? s.title : "\(s.title) · \(s.artist)", systemImage: s.playing ? "music.note" : "pause.fill")
                .font(DS.footnote)
        }
    }
}

/// The little equalizer by "LISTENING NOW".
struct MusicBars: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array([6.0, 11.0, 8.0, 13.0].enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 1).fill(DS.accent).frame(width: 3, height: CGFloat(h))
            }
        }
        .frame(height: 13, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The song as a card: the cover, "LISTENING NOW", the title, "artist · app" and "Open ↗" (only a known service's link).
struct ListeningCard: View {
    let music: LiveMusic
    @Environment(\.openURL) private var openURL

    var body: some View {
        let link: URL? = MusicShare.link(music.url).flatMap(URL.init(string:))
        HStack(spacing: DS.s12) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    MusicBars()
                    Text("LISTENING NOW").font(DS.caption).foregroundStyle(DS.accentText)
                }
                Text(music.title).font(DS.bodyStrong).foregroundStyle(DS.text).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(DS.sub).foregroundStyle(DS.secondary).lineLimit(1) }
            }
            Spacer(minLength: DS.s8)
            if let link {
                Button { openURL(link) } label: {
                    Text("Open ↗").font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(music.title)")
            }
        }
        .padding(DS.s12)
        .background(DS.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sub: String {
        let parts: [String] = [music.artist ?? "", music.app ?? ""].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var cover: some View {
        let tile = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let fallback = LinearGradient(colors: [Color(red: 0.49, green: 0.36, blue: 0.94), Color(red: 0.89, green: 0.33, blue: 0.53)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        if let u = MusicShare.cover(music.coverUrl).flatMap(URL.init(string:)) {
            AsyncImage(url: u) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                fallback.overlay(Text("♪").foregroundStyle(.white))
            }
            .frame(width: 52, height: 52).clipShape(tile)
            .accessibilityHidden(true)
        } else {
            fallback.overlay(Text("♪").font(.title3).foregroundStyle(.white))
                .frame(width: 52, height: 52).clipShape(tile)
                .accessibilityHidden(true)
        }
    }

    /// The song when it's fresh (under 10 minutes old by its own time).
    static func fresh(_ m: LiveMusic?, now: Date) -> LiveMusic? {
        guard let m, !m.title.isEmpty, let at = MusicShare.parseISO(m.at) else { return nil }
        let age: TimeInterval = now.timeIntervalSince(at)
        return age < MusicShare.maxAge ? m : nil
    }
}

/// A travelling friend's song (while it's under 10 minutes old), with "💬 Message" and "🎧 Listen too".
struct FriendListeningStrip: View {
    let friendId: String
    let name: String
    let music: LiveMusic
    @Environment(\.openURL) private var openURL

    static func fresh(_ m: LiveMusic?, now: Date) -> LiveMusic? { ListeningCard.fresh(m, now: now) }

    var body: some View {
        let link: URL? = MusicShare.link(music.url).flatMap(URL.init(string:))
        VStack(spacing: DS.s8) {
            ListeningCard(music: music)
                .accessibilityElement(children: .contain)
            HStack(spacing: DS.s8) {
                NavigationLink(value: FriendsRoute.chat(ChatKey.friend(friendId))) {
                    tile("💬 Message")
                }
                .buttonStyle(DSPressStyle())
                .accessibilityLabel("Message \(name)")
                if let link {
                    Button { openURL(link) } label: { tile("🎧 Listen too") }
                        .buttonStyle(DSPressStyle())
                        .accessibilityHint("Opens \(music.title) in \(music.app ?? "the music app")")
                }
            }
        }
    }

    private func tile(_ t: String) -> some View {
        Text(t).font(DS.subStrong).foregroundStyle(DS.text)
            .frame(maxWidth: .infinity, minHeight: DS.hit)
            .background(DS.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

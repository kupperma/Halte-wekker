import SwiftUI

/// Today's best and worst trip (0.35, `DailyRank`): on the Leaderboard (Settings › Trips & alarm, and Friends ›
/// Leaderboard with friends) and, small, on Friends. You and the friends who share their scores; on your own, against
/// your usual. It starts again at local midnight (the card looks again every minute).
struct TodayRankCard: View {
    /// Friends' small card: only when there's a trip today, and it opens the leaderboard.
    var compact = false
    @ObservedObject private var scores = ScoreBook.shared
    @ObservedObject private var together = FriendTogetherStore.shared
    @ObservedObject private var store = FriendStore.shared

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let rows: [DailyRank.Row] = DailyRank.rows(together.todayPeople(now: now), mine: scores.trips, now: now, calendar: .current)
        if rows.isEmpty {
            if !compact {
                VStack(alignment: .leading, spacing: DS.s8) {
                    DSHeader(title: "Today")
                    Text(store.hasFriends
                         ? "No trips today yet. Today’s fastest and slowest trip, yours and those of friends who share their scores, show here. It starts again at midnight."
                         : "No trips today yet. Your fastest and slowest trip today show here, next to your usual. It starts again at midnight.")
                        .font(DS.sub).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .dsPanel()
            }
        } else if compact {
            NavigationLink(value: FriendsRoute.leaderboard) { panel(rows, compact: true) }
                .buttonStyle(.plain)
        } else {
            panel(rows, compact: false)
        }
    }

    private func name(_ id: String) -> String { store.name(id) }

    private func panel(_ rows: [DailyRank.Row], compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? DS.s8 : DS.s12) {
            HStack(alignment: .firstTextBaseline) {
                Text(compact ? "Today’s trips" : "Today").font(DS.headline).foregroundStyle(DS.text).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if compact {
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DS.secondary).accessibilityHidden(true)
                } else {
                    let n: Int = rows.map(\.count).reduce(0, +)
                    Text(n == 1 ? "1 trip" : "\(n) trips").font(DS.footnote).monospacedDigit().foregroundStyle(DS.secondary)
                }
            }
            ForEach(rows, id: \.home) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.home ? "Home" : "To \(RoleWords.current.toSchoolWord)")
                        .font(DS.footnoteStrong).foregroundStyle(DS.secondary)
                    ForEach(DailyRank.lines(r, name: name), id: \.self) { l in
                        Text(l).font(compact ? DS.sub : DS.body).monospacedDigit().foregroundStyle(DS.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .contentShape(Rectangle())
        .dsPanel(padding: compact ? DS.s12 : DS.s16)
    }
}

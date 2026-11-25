import SwiftUI

// 0.39.1: the ride screen's cards for the wrong bus (`WrongBus`) and for another line's bus at your stop
// (`OtherAtStop`).

/// "You're on the 154 to Schijndel, not your 306" with the best way on ("Stay on to Schijndel — 306 from there at
/// 18:11"), and a way to close it.
struct WrongBusCard: View {
    @EnvironmentObject var trip: TripManager
    let alert: WrongBus.Alert

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s8) {
            Label(alert.title, systemImage: "exclamationmark.triangle.fill")
                .font(DS.headline).foregroundStyle(DS.warning)
                .fixedSize(horizontal: false, vertical: true)
            Text(alert.body).font(DS.bodyStrong).monospacedDigit().foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.s8) {
                DSQuietButton(title: "Pick again", icon: "hand.tap", full: true) { trip.pickAgain = true }
                DSQuietButton(title: "Got it", full: true) { trip.dismissWrongBus() }
            }
        }
        .accessibilityElement(children: .contain)
        .dsPanel()
    }
}

/// "That's the 154 to Schijndel — not yours" and "Your 306: 2 min", while you wait at the stop.
struct OtherAtStopCard: View {
    @EnvironmentObject var trip: TripManager
    let alert: WrongBus.Alert

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.s8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(DS.warning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(DS.bodyStrong).foregroundStyle(DS.warning).fixedSize(horizontal: false, vertical: true)
                Text(alert.body).font(DS.sub).monospacedDigit().foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { trip.dismissOtherAtStop() } label: {
                Image(systemName: "xmark").font(DS.sub).foregroundStyle(DS.secondary)
                    .frame(minWidth: DS.hit, minHeight: DS.hit).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .accessibilityElement(children: .contain)
        .dsPanel()
    }
}

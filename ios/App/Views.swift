import SwiftUI

enum Palette {
    static let blueA = Color(red: 0.27, green: 0.33, blue: 0.77)
    static let blueB = Color(red: 0.18, green: 0.23, blue: 0.56)
    static let sunA = Color(red: 0.83, green: 0.37, blue: 0.27)
    static let sunB = Color(red: 0.60, green: 0.20, blue: 0.34)
    static let night = Color(red: 0.03, green: 0.04, blue: 0.09)
}

struct RootView: View {
    @EnvironmentObject var trip: TripManager
    var body: some View {
        switch trip.phase {
        case .idle: HomeView()
        case .alarm: AlarmView()
        case .transfer, .finished: BetweenView()
        default: RideView()
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var trip: TripManager
    @State private var settings = false
    var home: Bool { trip.direction == .home }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.5)) { trip.direction = home ? .toSchool : .home }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GOING").font(.caption.weight(.bold)).opacity(0.85)
                                Text(trip.direction.title).font(.system(size: 34, weight: .heavy, design: .rounded))
                                Text(home ? "Breda → Veghel · tap to switch" : "Veghel → Breda · tap to switch").font(.subheadline).opacity(0.9)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.title2.weight(.bold))
                                .frame(width: 52, height: 52)
                                .background(.white.opacity(0.2), in: Circle())
                                .rotationEffect(.degrees(home ? 180 : 0))
                        }
                        .foregroundStyle(.white)
                        .padding(20)
                        .background(LinearGradient(colors: home ? [Palette.sunA, Palette.sunB] : [Palette.blueA, Palette.blueB],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)

                    Text("Wake me up").font(.title2.weight(.semibold))
                    VStack(spacing: 0) {
                        ForEach(RoutePlan.all) { r in
                            Button { trip.start(r) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(r.name).font(.headline)
                                        HStack(spacing: 6) {
                                            ForEach(Array(r.legs(trip.direction).enumerated()), id: \.offset) { i, l in
                                                if i > 0 { Text("—").foregroundStyle(.secondary) }
                                                Label(l.to.short, systemImage: l.mode.symbol)
                                            }
                                        }.font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle.fill").font(.title).foregroundStyle(home ? Palette.sunB : Palette.blueB)
                                }
                                .padding(16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if r.id != RoutePlan.all.last?.id { Divider() }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))

                    if trip.locationDenied {
                        Text("Location is off for Haltewekker. Turn it on in Settings → Privacy → Location Services, or it can’t wake you.")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                    Text("Start it once you’re on board. You can lock your phone and keep your music playing: it follows you with GPS and rings before your stop. Your trip shows on the lock screen and in the Dynamic Island.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Live times, planning and more on the website", destination: URL(string: "https://kupperma.github.io/Halte-wekker/")!)
                        .font(.footnote.weight(.semibold))
                }
                .padding(20)
            }
            .background(LinearGradient(colors: [home ? Color(red: 0.98, green: 0.80, blue: 0.72) : Color(red: 0.83, green: 0.86, blue: 1.0), Color(.systemGroupedBackground)],
                                       startPoint: .top, endPoint: .center).ignoresSafeArea())
            .navigationTitle("Haltewekker")
            .toolbar { Button { settings = true } label: { Image(systemName: "slider.horizontal.3") } }
            .sheet(isPresented: $settings) { SettingsView().presentationDetents([.medium, .large]) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var trip: TripManager
    var body: some View {
        NavigationStack {
            Form {
                Section("Wake me this far from my stop") {
                    Stepper("Bus: \(String(format: "%.1f", trip.busKm)) km", value: $trip.busKm, in: 0.5...10, step: 0.5)
                    Stepper("Train: \(String(format: "%.1f", trip.trainKm)) km", value: $trip.trainKm, in: 0.5...15, step: 0.5)
                }
                Section {
                    Toggle("Ring again at the stop", isOn: $trip.ringAtStop)
                } footer: {
                    Text("A second alarm when you arrive, in case you dozed off again.")
                }
                Section {
                    Text("The alarm plays over your music and also rings in silent mode. Keep the volume up or wear earbuds.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct RideView: View {
    @EnvironmentObject var trip: TripManager
    @State private var confirmEnd = false
    var body: some View {
        ZStack {
            Palette.night.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(trip.accuracy.map { "GPS ±\(Int($0)) m" } ?? "Finding GPS…", systemImage: "location.fill")
                        .font(.footnote).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white.opacity(0.08), in: Capsule())
                    Spacer()
                }
                Spacer()
                if trip.legs.count > 1 { Text("Leg \(trip.index + 1) of \(trip.legs.count)").font(.subheadline).foregroundStyle(.gray) }
                if let leg = trip.leg {
                    Label("\(leg.mode.title) to", systemImage: leg.mode.symbol).foregroundStyle(.gray).padding(.top, 10)
                    Text(leg.to.name).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(trip.distance.map { Fmt.distance($0).components(separatedBy: " ")[0] } ?? "–")
                        .font(.system(size: 88, weight: .heavy, design: .rounded))
                    Text(trip.distance.map { Fmt.distance($0).components(separatedBy: " ").last ?? "" } ?? "").font(.title2)
                }
                .foregroundStyle(.white.opacity(0.92)).padding(.top, 6)
                Text(trip.phase == .awake ? (trip.ringAtStop ? "You’re awake. It rings once more at the stop." : "You’re awake. Get your things ready.")
                                          : "It rings at \(Fmt.distance(trip.wakeKm * 1000)) from the stop.")
                    .foregroundStyle(.gray).padding(.top, 8)
                if let a = trip.arrival {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(trip.finalName) around \(Fmt.hhmm(a))").font(.title2.weight(.heavy)).foregroundStyle(.white.opacity(0.85))
                        if let n = trip.nextText { Text(n).foregroundStyle(.gray) }
                    }.padding(.top, 22)
                }
                Spacer()
                if trip.phase == .awake {
                    Button("I’m off, end this leg") { trip.legDone() }
                        .buttonStyle(.borderedProminent).tint(.white.opacity(0.15)).frame(maxWidth: .infinity).padding(.bottom, 8)
                }
                Button("End trip") { confirmEnd = true }
                    .frame(maxWidth: .infinity).padding().foregroundStyle(.gray)
                    .confirmationDialog("End this trip?", isPresented: $confirmEnd) { Button("End trip", role: .destructive) { trip.endTrip() } }
            }
            .padding(22)
        }
        .preferredColorScheme(.dark)
    }
}

struct AlarmView: View {
    @EnvironmentObject var trip: TripManager
    var approach: Bool { if case .alarm(let a) = trip.phase { return a }; return true }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.36), Color(red: 0.93, green: 0.44, blue: 0.27)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                Spacer()
                Text(approach ? "Wake up" : "Get off now").font(.system(size: 52, weight: .heavy, design: .rounded))
                Text(approach ? "\(trip.leg?.to.short ?? "Your stop") in about \(Fmt.distance(trip.distance ?? 0))." : "You’re at \(trip.leg?.to.short ?? "your stop").")
                    .font(.title3)
                Spacer()
                Button { trip.stopAlarm() } label: {
                    Text("Stop alarm").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(.white)
            }
            .foregroundStyle(Color(red: 0.2, green: 0.08, blue: 0))
            .padding(24)
        }
    }
}

struct BetweenView: View {
    @EnvironmentObject var trip: TripManager
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            if trip.phase == .transfer, let leg = trip.leg {
                Text("Change at \(leg.to.short)").font(.system(size: 36, weight: .heavy, design: .rounded))
                if let n = trip.nextText { Text(n).font(.title3).foregroundStyle(.secondary) }
                if let a = trip.arrival { Text("\(trip.finalName) around \(Fmt.hhmm(a))").font(.headline) }
                Spacer()
                Button { trip.nextLeg() } label: { Text("Start next leg").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16) }
                    .buttonStyle(.borderedProminent)
                Button("End trip here") { trip.endTrip() }.frame(maxWidth: .infinity).padding(.top, 4)
            } else {
                Text(trip.direction == .home ? "You’re home" : "You’re in Breda").font(.system(size: 36, weight: .heavy, design: .rounded))
                Text("Trip finished.").foregroundStyle(.secondary)
                Spacer()
                Button { trip.endTrip() } label: { Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}

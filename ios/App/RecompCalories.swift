import SwiftUI
import UserNotifications

/// "Add kcal": food that isn't one of the sources, so the day's calories include it. The kcal first (number pad,
/// 1…3000), then a name if you like ("Other food" without one).
struct KcalSheet: View {
    let button: String
    let done: (String, Double) -> Void

    private enum Field: Hashable { case kcal, name }

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kcal: String
    @FocusState private var focus: Field?

    init(name: String = "", kcal: Double? = nil, button: String, done: @escaping (String, Double) -> Void) {
        self.button = button
        self.done = done
        _name = State(initialValue: name)
        _kcal = State(initialValue: kcal.map { $0.isFinite ? String(Int($0.rounded())) : "" } ?? "")
    }

    var body: some View {
        let value = RecompInput.kcalEntry(kcal)
        return VStack(alignment: .leading, spacing: 12) {
            Text("How many kcal?")
                .font(HWFont.display(22)).foregroundStyle(Paper.ink)
            field("kcal", text: $kcal, .kcal, keyboard: .numberPad, prompt: "", unit: "kcal")
            field("What (optional)", text: $name, .name, keyboard: .default, prompt: ProteinEntry.otherFood)
            if !kcal.isEmpty, value == nil {
                Text("From 1 to 3000 kcal.")
                    .font(BoardInk.sans(13, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
            }
            Button(button) {
                guard let value else { return }
                done(name, value)
                dismiss()
            }
            .buttonStyle(RecompButtonStyle(wide: true, height: 52))
            .disabled(value == nil)
        }
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PaperFill().ignoresSafeArea())
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.light)
        .task {
            try? await Task.sleep(nanoseconds: 100_000_000)       // once the field is on screen
            focus = .kcal
        }
    }

    /// A field on paper, as on the scan sheet. The whole box takes the tap.
    private func field(_ title: String, text: Binding<String>, _ which: Field, keyboard: UIKeyboardType,
                       prompt: String, unit: String? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return HStack(spacing: 6) {
            TextField(title, text: text, prompt: Text(verbatim: prompt))
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .focused($focus, equals: which)
                .font(BoardInk.sans(17, .semibold))
                .monospacedDigit()
                .foregroundStyle(Paper.ink)
            if let unit {
                Text(verbatim: unit)
                    .font(BoardInk.sans(17, .semibold)).foregroundStyle(RecompStyle.quiet)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background { shape.fill(Paper.paper).onTapGesture { focus = which } }
        .overlay(shape.stroke(focus == which ? RecompStyle.accent : Paper.edge, lineWidth: 1.2).allowsHitTesting(false))
    }
}

/// The one notice a day at the calorie limit. Only with the notification permission the app already has (asked for
/// the trips); never asks for it here.
enum RecompKcalNotice {
    static func post(total: Double, limit: Double, day: DayKey) {
        let title = KcalMath.noticeTitle
        let body = KcalMath.noticeBody(total: total, limit: limit)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: break
            default: return
            }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = body
            n.sound = .default
            n.userInfo = ["kind": "info"]
            center.add(UNNotificationRequest(identifier: idPrefix + day, content: n, trigger: nil)) { _ in }
        }
    }

    /// In the app it shows as a banner over the open sheets (see TripManager's `willPresent`).
    static let idPrefix = "recomp-kcal-"
}

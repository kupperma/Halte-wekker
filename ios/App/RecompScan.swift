import SwiftUI
import AVFoundation
import Vision
import VisionKit

/// Scan a pack (or type its barcode), find out how much protein a pack has, and say how much of it you had.
/// One step at a time inside the sheet: the camera, "Looking it up…", the label (when Open Food Facts can't help),
/// and the amount: in slices or pieces when the serving is known (or counted), else part of the pack.
/// A product found once is remembered on the phone, so it works without internet the next time.
struct ScanSheet: View {
    @ObservedObject private var store = RecompStore.shared
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case scan
        case lookingUp(String)
        /// Type the protein from the label: Open Food Facts doesn't have it, there was no internet, or the
        /// remembered number was wrong.
        case label(String, LabelReason)
        case amount(String)
        /// "How many slices are in the pack?", to count it by portion from then on.
        case portions(String)
    }

    /// Why the label form is up. It sets the one line under its title.
    private enum LabelReason: Equatable {
        /// Open Food Facts doesn't know the code.
        case unknown
        /// It knows the product, but not its protein (or not a believable amount).
        case noProtein
        case offline
        /// From the amount step: the remembered protein was wrong.
        case correcting
    }

    private enum Camera { case checking, ready, unavailable }
    private enum Field: Hashable { case barcode, name, protein, count }

    /// A code just left with Back. The camera is usually still on it, so it's ignored for a moment.
    private struct LeftCode {
        let code: String
        let at: Date
    }

    @State private var step: Step = .scan
    @State private var camera: Camera = .checking
    @State private var cameraOff = false
    @State private var typing = false
    @State private var typed = ""
    @State private var name = ""
    @State private var protein = ""
    @State private var fraction: Double = 1
    /// Slices (or pieces, portions) for a product counted by portion.
    @State private var portions: Double = 1
    /// A product counted by portion, and a part of the pack tapped instead: Add logs that part.
    @State private var packChosen = false
    /// The "How many … are in the pack?" answer, and what they're called.
    @State private var count = ""
    @State private var portionPick = PortionName.choices[0]
    /// A portion Open Food Facts knew for a pack it had no protein for: kept once the label is typed.
    @State private var pendingPortion: Portion?
    /// For a product remembered before portions: Open Food Facts asked once more, quietly, for its serving.
    @State private var refresh: Task<Void, Never>?
    @State private var attempt = 0
    @State private var lookup: Task<Void, Never>?
    @State private var justLeft: LeftCode?
    @State private var scans = 0
    @State private var addedSource = false
    @FocusState private var focus: Field?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(PaperFill().ignoresSafeArea())
                .navigationTitle("Scan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if step != .scan {
                            Button { back() } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                                    Text("Back")
                                }
                            }
                            .foregroundStyle(Paper.navy)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") { dismiss() }.foregroundStyle(Paper.navy)
                    }
                }
        }
        .preferredColorScheme(.light)
        .presentationDragIndicator(.visible)
        .task { await checkCamera() }
        .onDisappear {
            lookup?.cancel()
            refresh?.cancel()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: scans)
        .sensoryFeedback(.selection, trigger: fraction)
        .sensoryFeedback(.selection, trigger: portions)
        .sensoryFeedback(.selection, trigger: packChosen)
        .sensoryFeedback(.selection, trigger: portionPick)
        .sensoryFeedback(.success, trigger: addedSource) { _, new in new }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .scan:
            if typing || camera == .unavailable {
                typeView
            } else {
                cameraView
            }
        case .lookingUp(let code):
            lookingUpView(code)
        case .label(let code, let reason):
            labelView(code, reason)
        case .amount(let code):
            if let p = store.data.products[code] {
                amountView(code, p)
            }
        case .portions(let code):
            if let p = store.data.products[code] {
                portionsView(code, p)
            }
        }
    }

    // MARK: - The camera

    private var cameraView: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return VStack(spacing: 12) {
            Text("Point the camera at the barcode")
                .font(BoardInk.sans(15, .medium)).foregroundStyle(Paper.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Paper.ink
                if camera == .ready {
                    BarcodeScanner(found: scanned, lost: cameraLost)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(shape)
            .overlay(shape.stroke(Paper.edge, lineWidth: 1.2).allowsHitTesting(false))
            Button("Type the barcode") { startTyping() }
                .buttonStyle(RecompButtonStyle(filled: false, wide: true, height: 52))
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        .transition(.opacity)
    }

    // MARK: - Typing the code

    /// ASCII digits only, so a pasted "87 10400 …" still works.
    private var typedCode: String { OpenFoodFacts.digits(in: typed) }

    private var typeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Type the barcode")
                    .font(HWFont.display(22)).foregroundStyle(Paper.ink)
                if cameraOff {
                    Text("Camera access is off. You can turn it on in Settings.")
                        .font(BoardInk.sans(13, .medium)).foregroundStyle(RecompStyle.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    field("Barcode", text: $typed, .barcode, keyboard: .numberPad)
                    Button("Look up") { handle(typedCode) }
                        .buttonStyle(RecompButtonStyle())
                        .disabled(!OpenFoodFacts.isBarcode(typedCode))
                }
                if camera == .ready {
                    Button("Use the camera") {
                        focus = nil
                        withAnimation(.easeOut(duration: 0.2)) { typing = false }
                    }
                    .buttonStyle(RecompButtonStyle(filled: false, wide: true))
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .transition(.opacity)
    }

    // MARK: - Looking it up

    private func lookingUpView(_ code: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(Paper.ink)
            Text("Looking it up…")
                .font(BoardInk.sans(17)).foregroundStyle(Paper.ink)
            Text(verbatim: code)
                .font(BoardInk.sans(13, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    // MARK: - From the label

    private func labelView(_ code: String, _ reason: LabelReason) -> some View {
        let offline = reason == .offline
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("How much protein is in a pack?")
                    .font(HWFont.display(22)).foregroundStyle(Paper.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if offline {
                    Text("No internet. Type the protein from the label, or try again later.")
                        .font(BoardInk.sans(14, .medium)).foregroundStyle(Paper.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let why = Self.why(reason) {
                    Text(verbatim: why)
                        .font(BoardInk.sans(14, .medium)).foregroundStyle(RecompStyle.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                labelled("Name") {
                    field("Name", text: $name, .name, keyboard: .default, prompt: OpenFoodFacts.fallbackName)
                }
                labelled("Protein per pack (from the label)") {
                    field("Protein per pack (from the label)", text: $protein, .protein, keyboard: .decimalPad,
                          prompt: "", unit: "g")
                }
                Button("Save") { saveLabel(code) }
                    .buttonStyle(RecompButtonStyle(wide: true, height: 52))
                    .disabled(RecompInput.protein(protein) == nil)
                    .padding(.top, 4)
                if offline {
                    Button("Try again") { lookUp(code) }
                        .buttonStyle(RecompButtonStyle(filled: false, wide: true))
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .transition(.opacity)
    }

    /// The quiet line under the title: why there's a form at all.
    private static func why(_ reason: LabelReason) -> String? {
        switch reason {
        case .unknown: return "Open Food Facts doesn't know this one."
        case .noProtein: return "Open Food Facts has no protein for this one."
        case .offline, .correcting: return nil
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(BoardInk.sans(13, .medium)).foregroundStyle(RecompStyle.quiet)
                .accessibilityHidden(true)                  // the field carries the same words
            content()
        }
    }

    // MARK: - How much

    /// Most portions at once, as on the source sheets.
    private static let mostPortions: Double = 20

    /// With a portion known: − 1 slice + first, part of the pack below it. Without: part of the pack, and the way
    /// to count it by portion.
    private func amountView(_ code: String, _ p: KnownProduct) -> some View {
        let portion = p.portion
        let byPortion = portion != nil && !packChosen
        let grams = byPortion ? portions * (portion?.protein ?? 0) : fraction * p.proteinPerPack
        return VStack(spacing: 14) {
            Text(verbatim: p.name.isEmpty ? OpenFoodFacts.fallbackName : p.name)
                .font(HWFont.display(24)).foregroundStyle(Paper.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.7)
            if let portion {
                portionStepper(portion, active: byPortion)
            } else {
                fractionRow(small: false)
            }
            Text(verbatim: "≈ \(RecompFormat.grams(grams)) protein")
                .font(BoardInk.sans(15, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
                .contentTransition(.numericText(value: grams))
            if portion != nil {
                VStack(spacing: 6) {
                    Text("Or by the pack")
                        .font(BoardInk.sans(13, .medium)).foregroundStyle(RecompStyle.quiet)
                        .accessibilityHidden(true)              // each button says "… of the pack"
                    fractionRow(small: true)
                }
            } else {
                Button("Count by slice or portion") { askPortions(code, p) }
                    .buttonStyle(RecompButtonStyle(filled: false, wide: true))
            }
            Button("Add") {
                add(code, p)
                dismiss()
            }
            .buttonStyle(RecompButtonStyle(wide: true, height: 52))
            .padding(.top, 6)
            sourceButton(code)
                .padding(.top, 6)
            links(code, p)
        }
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
        .transition(.opacity)
    }

    /// − "2 slices" +: from 1 to 20. Dimmed while a part of the pack is chosen; a tap on any of it counts slices again.
    private func portionStepper(_ portion: Portion, active: Bool) -> some View {
        HStack(spacing: 12) {
            stepButton("minus", label: "Fewer \(portion.units)", enabled: !active || portions > 1) {
                portions = max(1, portions - 1)
                packChosen = false
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { packChosen = false }
            } label: {
                Text(verbatim: ProteinMath.amountLabel(portions, unit: portion.name, units: portion.units))
                    .font(HWFont.display(32)).monospacedDigit()
                    .foregroundStyle(active ? Paper.ink : RecompStyle.quiet)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .contentShape(Rectangle())
                    .contentTransition(.numericText(value: portions))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
            stepButton("plus", label: "More \(portion.units)", enabled: !active || portions < Self.mostPortions) {
                portions = min(Self.mostPortions, portions + 1)
                packChosen = false
            }
        }
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, _ go: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { go() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold)).foregroundStyle(Paper.ink)
                .frame(width: 64, height: 64)
                .background(Paper.card, in: Circle())
                .overlay(Circle().stroke(Paper.edge, lineWidth: 1.2))
                .contentShape(Circle())
        }
        .buttonStyle(RecompPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    /// ¼ ½ ¾ All. Big when it's the only way to say how much; small under the slices, and only lit once tapped.
    private func fractionRow(small: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(ProteinMath.packFractions, id: \.self) { f in
                let on = (!small || packChosen) && abs(fraction - f) < 0.001
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        fraction = f
                        packChosen = true
                    }
                } label: {
                    Text(verbatim: Self.fractionText(f))
                }
                .buttonStyle(RecompFractionStyle(selected: on, font: HWFont.display(small ? 19 : 26),
                                                 height: small ? 44 : 64))
                .accessibilityLabel(Self.fractionSpoken(f) + (small ? " of the pack" : ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// The quiet ways to put a number right: the pack's protein, and (counted by portion) how many are in a pack.
    @ViewBuilder private func links(_ code: String, _ p: KnownProduct) -> some View {
        let wrong = quietLink("Wrong? Type it from the label") { correct(code, p) }
        if let portion = p.portion {
            let recount = quietLink("Count the \(portion.units)") { askPortions(code, p) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { wrong; recount }
                VStack(spacing: 0) { wrong; recount }
            }
        } else {
            wrong
        }
    }

    private func quietLink(_ title: String, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Text(verbatim: title)
                .underline()
                .font(BoardInk.sans(13, .medium)).foregroundStyle(RecompStyle.quiet)
                .lineLimit(1)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add(_ code: String, _ p: KnownProduct) {
        if p.portion != nil, !packChosen {
            store.addProductPortions(barcode: code, count: portions)
        } else {
            store.addProduct(barcode: code, fraction: fraction)
        }
    }

    /// "Add to my sources", or why it can't be.
    @ViewBuilder private func sourceButton(_ code: String) -> some View {
        let inSources = store.data.sources.contains { $0.barcode == code }
        let full = store.data.sources.count >= RecompData.maxSources
        let note: String? = addedSource ? "Added to your sources."
            : inSources ? "Already in your sources."
            : full ? "Up to \(RecompData.maxSources) sources. Remove one to add another."
            : nil
        VStack(spacing: 6) {
            Button("Add to my sources") {
                if store.addToSources(barcode: code) { addedSource = true }
            }
            .buttonStyle(RecompButtonStyle(filled: false, wide: true))
            .disabled(inSources || full)
            if let note {
                Text(verbatim: note)
                    .font(BoardInk.sans(13, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "¼" "½" "¾" "All"
    private static func fractionText(_ f: Double) -> String {
        f >= 1 - 0.001 ? "All" : ProteinMath.amountText(f)
    }

    private static func fractionSpoken(_ f: Double) -> String {
        switch f {
        case ..<0.3: return "A quarter"
        case ..<0.6: return "Half"
        case ..<0.9: return "Three quarters"
        default: return "All"
        }
    }

    // MARK: - How many in a pack

    /// "How many slices are in the pack?": slice, piece or portion, the number, and what one is in protein.
    private func portionsView(_ code: String, _ p: KnownProduct) -> some View {
        let units = PortionName.plural(portionPick)
        let n = RecompInput.portions(count)
        let one = n.flatMap { Portion.split(pack: p.proteinPerPack, into: $0, name: portionPick) }
        let hint: String = one.map { "≈ \(RecompFormat.grams($0.protein)) protein a \($0.name)" }
            ?? (count.isEmpty ? " "
                : n == nil ? "A whole number from 1 to 200."
                : "Too little protein a \(portionPick) to count. Count by the pack.")
        // A name it came with that isn't one of the three ("bar") stays on offer.
        var names = PortionName.choices
        if let other = p.portionName, !names.contains(other) { names.append(other) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "How many \(units) are in the pack?")
                    .font(HWFont.display(22)).foregroundStyle(Paper.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(names, id: \.self) { name in
                        let on = portionPick == name
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { portionPick = name }
                        } label: {
                            Text(verbatim: name.capitalized)
                        }
                        .buttonStyle(RecompFractionStyle(selected: on, font: BoardInk.sans(15), height: 44))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                field("Number of \(units)", text: $count, .count, keyboard: .numberPad, prompt: "", unit: units)
                Text(verbatim: hint)
                    .font(BoardInk.sans(14, .medium)).monospacedDigit().foregroundStyle(RecompStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Save") { savePortions(code, p) }
                    .buttonStyle(RecompButtonStyle(wide: true, height: 52))
                    .disabled(one == nil)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .transition(.opacity)
    }

    // MARK: - Fields

    /// A field on paper. The whole box takes the tap, not just the text in it.
    private func field(_ title: String, text: Binding<String>, _ which: Field, keyboard: UIKeyboardType,
                       prompt: String? = nil, unit: String? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return HStack(spacing: 6) {
            TextField(title, text: text, prompt: Text(verbatim: prompt ?? title))
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

    // MARK: - The flow

    @MainActor
    private func checkCamera() async {
        var ready = false
        if DataScannerViewController.isSupported {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            cameraOff = status == .denied || status == .restricted
            ready = !cameraOff && DataScannerViewController.isAvailable
        }
        withAnimation(.easeOut(duration: 0.2)) { camera = ready ? .ready : .unavailable }
        // No camera from the start: the barcode field is all there is, so the keyboard comes up with it.
        if !ready, step == .scan, !typing { focusSoon(.barcode) }
    }

    /// The camera stopped working while it was on screen (taken away, or access turned off): type the code instead.
    private func cameraLost() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraOff = status == .denied || status == .restricted
        withAnimation(.easeOut(duration: 0.2)) { camera = .unavailable }
    }

    /// From the camera. false: not taken (the scanner keeps looking).
    private func scanned(_ code: String) -> Bool {
        guard step == .scan, !typing, camera == .ready, OpenFoodFacts.isBarcode(code) else { return false }
        if let l = justLeft, l.code == code, Date().timeIntervalSince(l.at) < 2 { return false }
        scans += 1
        handle(code)
        return true
    }

    private func startTyping() {
        withAnimation(.easeOut(duration: 0.2)) { typing = true }
        focusSoon(.barcode)
    }

    /// A new code, from the camera or typed: a known product goes straight to the amount, anything else is looked up.
    private func handle(_ code: String) {
        guard step == .scan, OpenFoodFacts.isBarcode(code) else { return }
        focus = nil
        name = ""
        protein = ""
        pendingPortion = nil
        if store.data.products[code] != nil {
            showAmount(code)
            refreshPortion(code)
        } else {
            lookUp(code)
        }
    }

    /// A product remembered without a portion (scanned before 0.17.1, say): ask Open Food Facts again, quietly, and
    /// count it by slice once it knows the serving. Offline or nothing new: it stays as it is.
    private func refreshPortion(_ code: String) {
        refresh?.cancel()
        guard store.data.products[code]?.portion == nil else { return }
        refresh = Task { @MainActor in
            let result = await OpenFoodFacts.lookup(code)
            guard !Task.isCancelled else { return }
            let answer: Portion?
            switch result {
            case .found(_, _, let p), .needsProtein(_, let p): answer = p
            case .offline: answer = nil
            }
            // Counted by hand in the meantime, or not a part of the pack as remembered: leave it.
            guard let found = answer, let now = store.data.products[code], now.portion == nil,
                  found.isPart(of: now.proteinPerPack) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                store.rememberPortion(barcode: code, name: found.name, proteinPerPortion: found.protein)
            }
        }
    }

    private func lookUp(_ code: String) {
        guard OpenFoodFacts.isBarcode(code) else { return }   // OpenFoodFacts.url(for:) needs a clean code
        lookup?.cancel()
        attempt += 1
        let mine = attempt
        focus = nil
        move(to: .lookingUp(code))
        lookup = Task { @MainActor in
            let result = await OpenFoodFacts.lookup(code)
            // The sheet moved on (Back, another code, closed): this answer is for nobody.
            guard !Task.isCancelled, mine == attempt, step == .lookingUp(code) else { return }
            switch result {
            case .found(let n, let g, let portion):
                store.rememberProduct(barcode: code, name: n, proteinPerPack: g, portion: portion)
                showAmount(code)
            case .needsProtein(let n, let portion):
                pendingPortion = portion
                let known = !(n ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                askLabel(code, name: n, known ? .noProtein : .unknown)
            case .offline:
                askLabel(code, name: nil, .offline)
            }
        }
    }

    private func askLabel(_ code: String, name n: String?, _ reason: LabelReason) {
        if let n, !n.isEmpty { name = n }
        move(to: .label(code, reason))
        focusSoon(.protein)
    }

    /// From the amount step: type the protein again for a product already remembered. Saving overwrites it, and
    /// keeps its portion.
    private func correct(_ code: String, _ p: KnownProduct) {
        name = p.name
        protein = ""
        pendingPortion = nil
        askLabel(code, name: nil, .correcting)
    }

    private func saveLabel(_ code: String) {
        guard let g = RecompInput.protein(protein) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let portion = pendingPortion.flatMap { $0.isPart(of: g) ? $0 : nil }
        store.rememberProduct(barcode: code, name: n.isEmpty ? OpenFoodFacts.fallbackName : n, proteinPerPack: g,
                              portion: portion)
        pendingPortion = nil
        focus = nil
        showAmount(code)
    }

    /// Count by portion: slice to start with; with a portion already, its name and about how many a pack holds.
    private func askPortions(_ code: String, _ p: KnownProduct) {
        if let portion = p.portion {
            portionPick = portion.name
            let n = (p.proteinPerPack / portion.protein).rounded()
            count = n.isFinite && Portion.perPackRange.contains(n) ? String(Int(n)) : ""
        } else {
            portionPick = PortionName.choices[0]
            count = ""
        }
        move(to: .portions(code))
        focusSoon(.count)
    }

    private func savePortions(_ code: String, _ p: KnownProduct) {
        guard let n = RecompInput.portions(count),
              let one = Portion.split(pack: p.proteinPerPack, into: n, name: portionPick) else { return }
        store.rememberPortion(barcode: code, name: one.name, proteinPerPortion: one.protein)
        focus = nil
        showAmount(code)
    }

    private func showAmount(_ code: String) {
        fraction = 1
        portions = 1
        packChosen = false
        addedSource = false
        move(to: .amount(code))
    }

    private func back() {
        lookup?.cancel()
        attempt += 1
        focus = nil
        // Correcting a remembered product, or counting its portions: Back is to its amount again, as it was.
        if case .label(let code, .correcting) = step, store.data.products[code] != nil {
            move(to: .amount(code))
            return
        }
        if case .portions(let code) = step, store.data.products[code] != nil {
            move(to: .amount(code))
            return
        }
        switch step {
        case .lookingUp(let code), .label(let code, _), .amount(let code), .portions(let code):
            justLeft = LeftCode(code: code, at: Date())
        case .scan:
            break
        }
        move(to: .scan)
    }

    private func move(to next: Step) {
        withAnimation(.easeOut(duration: 0.2)) { step = next }
    }

    /// Once the field is on screen.
    private func focusSoon(_ f: Field) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            focus = f
        }
    }
}

// MARK: - The scanner

/// VisionKit's live barcode scanner (EAN-13, EAN-8, UPC-E), with its own highlighting. It hands back the first code
/// that looks like a barcode and that `found` takes, then stops.
private struct BarcodeScanner: UIViewControllerRepresentable {
    let found: @MainActor (String) -> Bool
    let lost: @MainActor () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.found = found
        context.coordinator.lost = lost
        context.coordinator.start(scanner)
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found, lost: lost) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var found: @MainActor (String) -> Bool
        var lost: @MainActor () -> Void
        private var done = false

        init(found: @escaping @MainActor (String) -> Bool, lost: @escaping @MainActor () -> Void) {
            self.found = found
            self.lost = lost
        }

        func start(_ scanner: DataScannerViewController) {
            guard !done, !scanner.isScanning else { return }
            do {
                try scanner.startScanning()
            } catch {
                // Not available after all (restricted, or no camera): type the code instead. Not during this view update.
                done = true
                Task { @MainActor [weak self] in self?.lost() }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            take(addedItems, from: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            take(updatedItems, from: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            take([item], from: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            done = true
            lost()
        }

        /// Only once: the scanner calls back many times a second while the code is in view.
        private func take(_ items: [RecognizedItem], from scanner: DataScannerViewController) {
            guard !done else { return }
            for item in items {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      OpenFoodFacts.isBarcode(payload) else { continue }
                if found(payload) {
                    done = true
                    scanner.stopScanning()
                }
                return
            }
        }
    }
}

// MARK: - Buttons

/// ¼ ½ ¾ All (and slice / piece / portion): paper buttons side by side; the chosen one is filled with the accent.
private struct RecompFractionStyle: ButtonStyle {
    let selected: Bool
    var font: Font = HWFont.display(26)
    var height: CGFloat = 64

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        let pressed = configuration.isPressed
        return configuration.label
            .font(font).monospacedDigit()
            .foregroundStyle(selected ? Color.white : Paper.ink)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(selected ? RecompStyle.accent : Paper.paper, in: shape)
            .overlay(shape.stroke(selected ? Color.clear : Paper.edge, lineWidth: 1.2))
            .contentShape(shape)
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

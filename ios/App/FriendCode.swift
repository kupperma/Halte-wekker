import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// Friends (0.25): your code as a QR code, and the camera that reads someone else's.

/// A QR code, black on white (whatever the phone's light or dark: scanners want the contrast).
struct QRCodeImage: View {
    let text: String
    var body: some View {
        Group {
            if let img = Self.make(text) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
            } else {
                Color.white
            }
        }
        .padding(DS.s16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: DS.fieldRadius, style: .continuous))
    }

    static func make(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Friends › Show my code: the QR code with your name, and the link to send.
struct MyFriendCodeSheet: View {
    @ObservedObject private var store = FriendStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.s16) {
                    if let link = store.shareLink {
                        QRCodeImage(text: link.absoluteString)
                            .frame(maxWidth: 300)
                            .accessibilityLabel("Your friend code, as a QR code")
                        Text(store.book?.myName ?? "")
                            .font(DS.title).foregroundStyle(DS.text)
                            .multilineTextAlignment(.center)
                        Text("Your friend scans this in Haltewekker (Friends › Scan a code), or with their phone’s camera.")
                            .font(DS.sub).foregroundStyle(DS.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        ShareLink(item: link, subject: Text("My Haltewekker friend code"),
                                  message: Text("Add me as a friend in Haltewekker")) {
                            Label("Send my link instead", systemImage: "square.and.arrow.up")
                                .font(DS.bodyStrong)
                                .foregroundStyle(DS.onAccent)
                                .frame(maxWidth: .infinity, minHeight: DS.cta)
                                .background(DS.accent, in: Capsule())
                        }
                        .buttonStyle(DSPressStyle())
                        Text("The link and the code hold your name and your public keys, nothing else.")
                            .font(DS.footnote).foregroundStyle(DS.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s24)
                .frame(maxWidth: .infinity)
            }
            .background(DS.page.ignoresSafeArea())
            .navigationTitle("My friend code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(DS.accentText)
    }
}

/// Friends › Scan a code: the camera, looking for a friend code.
struct ScanFriendSheet: View {
    let found: (FriendStore.OpenedCode) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var wrong = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch status {
                case .authorized:
                    QRScannerView(onCode: take).ignoresSafeArea()
                    frame
                case .notDetermined:
                    ProgressView().tint(.white)
                default:
                    denied
                }
            }
            .navigationTitle("Scan a friend code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(DS.accentText)
        .task {
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private var frame: some View {
        VStack(spacing: DS.s16) {
            Spacer()
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)
                .accessibilityHidden(true)
            Text(wrong ? "That’s not a Haltewekker friend code." : "Point the camera at your friend’s code.")
                .font(DS.bodyStrong).foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.s16).padding(.vertical, DS.s12)
                .background(Color.black.opacity(0.6), in: Capsule())
            Spacer()
        }
        .padding(DS.s16)
    }

    private var denied: some View {
        VStack(spacing: DS.s16) {
            Image(systemName: "camera").font(.largeTitle).foregroundStyle(.white).accessibilityHidden(true)
            Text("Haltewekker may not use the camera. Allow it in Settings to scan a friend code, or ask your friend to send their link.")
                .font(DS.body).foregroundStyle(.white).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
            }
            .font(DS.bodyStrong)
        }
        .padding(DS.s24)
    }

    private func take(_ text: String) {
        guard let c = FriendLink.parse(text) else { wrong = true; return }
        found(FriendStore.OpenedCode(card: c.card, name: c.name))
        dismiss()
    }
}

/// The camera, reading QR codes (AVFoundation). Hands each new code it sees to `onCode`, on the main thread.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let c = QRScannerController()
        c.onCode = onCode
        return c
    }
    func updateUIViewController(_ c: QRScannerController, context: Context) { c.onCode = onCode }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var last: String?
    private let queue = DispatchQueue(label: "nl.haltewekker.qrscan")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let out = AVCaptureMetadataOutput()
        guard session.canAddOutput(out) else { return }
        session.addOutput(out)
        out.setMetadataObjectsDelegate(self, queue: .main)
        if out.availableMetadataObjectTypes.contains(.qr) { out.metadataObjectTypes = [.qr] }
        let p = AVCaptureVideoPreviewLayer(session: session)
        p.videoGravity = .resizeAspectFill
        view.layer.addSublayer(p)
        preview = p
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let s = session
        queue.async { if !s.isRunning { s.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let codes: [String] = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        // (delivered on the main queue: set up so in viewDidLoad)
        MainActor.assumeIsolated { self.take(codes) }
    }

    private func take(_ codes: [String]) {
        guard let code = codes.first, code != last else { return }
        last = code
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onCode?(code)
    }
}

/// Follows the phone's own light or dark, even over a home that's kept dark (Next trip first).
struct FollowSystemScheme: ViewModifier {
    @Environment(\.scenePhase) private var scene
    @State private var scheme: ColorScheme?

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(scheme)
            .onAppear { scheme = Self.system() }
            .onChange(of: scene) { _, s in if s == .active { scheme = Self.system() } }
    }

    @MainActor static func system() -> ColorScheme? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let s = scenes.first else { return nil }
        return s.screen.traitCollection.userInterfaceStyle == .dark ? .dark : .light
    }
}

extension View {
    func followsSystemScheme() -> some View { modifier(FollowSystemScheme()) }
}

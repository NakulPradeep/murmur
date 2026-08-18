import AppKit
import SwiftUI

/// A small floating indicator so it is always obvious when the microphone is
/// live.
///
/// The panel must never take focus — the whole point is that the user keeps
/// typing in another app — hence `.nonactivatingPanel`, no key/main status, and
/// mouse events passing straight through.
/// A panel that accepts a drag but can never become key or main.
///
/// Overriding both is what keeps the pill from stealing focus when it is
/// clicked — `.nonactivatingPanel` alone governs activation, not key status,
/// and without these the app you are dictating into loses its cursor.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecordingOverlay {
    private var panel: OverlayPanel?
    private let model = OverlayModel()
    private var moveObserver: NSObjectProtocol?

    func update(state: DictationController.State, level: Float, caption: String = "") {
        model.state = state
        model.level = level
        model.caption = caption

        if state == .idle {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        if panel == nil { build() }
        guard let panel, !panel.isVisible else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func build() {
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: OverlayMetrics.width, height: OverlayMetrics.height)

        let panel = OverlayPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Draggable, so it can live wherever it does not cover your work.
        // It only appears while dictating, so the short spell of intercepting
        // clicks costs less than being stuck in one place.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // Follow the user across spaces and over full-screen apps.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        self.panel = panel

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { note in
            guard let moved = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { Self.savePosition(moved.frame.origin) }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    // MARK: - Remembered position

    private static func savePosition(_ origin: NSPoint) {
        Prefs.defaults.set(["x": origin.x, "y": origin.y], forKey: PrefKey.overlayPosition)
    }

    static func resetPosition() {
        Prefs.defaults.removeObject(forKey: PrefKey.overlayPosition)
    }

    static var hasCustomPosition: Bool {
        Prefs.defaults.dictionary(forKey: PrefKey.overlayPosition) != nil
    }

    /// A saved position is only used if it is still on a connected display —
    /// otherwise unplugging a monitor would hide the pill off-screen with no
    /// obvious way to get it back.
    private static func savedPosition(for size: NSSize) -> NSPoint? {
        guard let d = Prefs.defaults.dictionary(forKey: PrefKey.overlayPosition),
              let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
        let rect = NSRect(x: x, y: y, width: size.width, height: size.height)
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        return visible ? NSPoint(x: x, y: y) : nil
    }

    /// Wherever the user last dragged it, else bottom-centre of whichever
    /// screen has the mouse, clear of the Dock.
    private func position(_ panel: NSPanel) {
        if let saved = Self.savedPosition(for: panel.frame.size) {
            panel.setFrameOrigin(saved)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 28))
    }
}

enum OverlayMetrics {
    /// Wide enough for a line of live caption without dominating the screen.
    static let width: CGFloat = 420
    static let height: CGFloat = 56
}

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var state: DictationController.State = .idle
    @Published var level: Float = 0
    @Published var caption: String = ""
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    private var label: String {
        switch model.state {
        case .idle: return ""
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .polishing: return "Polishing"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            if model.state == .recording {
                LevelMeter(level: model.level)
                    .frame(width: 42, height: 18)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 42)
            }

            // Once words start arriving they replace the state label: seeing
            // your own sentence is far better feedback than the word
            // "Listening".
            if model.state == .recording, !model.caption.isEmpty {
                Text(model.caption)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: OverlayMetrics.width, height: OverlayMetrics.height)
        .animation(.easeOut(duration: 0.12), value: model.caption)
        .background(
            RoundedRectangle(cornerRadius: OverlayMetrics.height / 2, style: .continuous)
                .fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: OverlayMetrics.height / 2, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// Simple bar meter. Bars are driven from one smoothed level rather than an FFT
/// — this only needs to say "the mic is hearing you", and a real spectrum would
/// cost far more CPU than the signal is worth.
private struct LevelMeter: View {
    let level: Float
    private let bars = 5

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: height(for: index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        // Centre bars react most, which reads as a voice rather than a bar chart.
        let centre = Double(bars - 1) / 2
        let distance = abs(Double(index) - centre) / max(centre, 1)
        let weight = 1.0 - distance * 0.55
        let value = Double(min(max(level, 0), 1)) * weight
        return CGFloat(4 + value * 14)
    }
}

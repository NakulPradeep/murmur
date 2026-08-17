import AppKit
import SwiftUI

/// A small floating indicator so it is always obvious when the microphone is
/// live.
///
/// The panel must never take focus — the whole point is that the user keeps
/// typing in another app — hence `.nonactivatingPanel`, no key/main status, and
/// mouse events passing straight through.
@MainActor
final class RecordingOverlay {
    private var panel: NSPanel?
    private let model = OverlayModel()

    func update(state: DictationController.State, level: Float) {
        model.state = state
        model.level = level

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
        hosting.frame = NSRect(x: 0, y: 0, width: 190, height: 44)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Follow the user across spaces and over full-screen apps.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        self.panel = panel
    }

    /// Bottom-centre of whichever screen has the mouse, clear of the Dock.
    private func position(_ panel: NSPanel) {
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

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var state: DictationController.State = .idle
    @Published var level: Float = 0
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
        HStack(spacing: 10) {
            if model.state == .recording {
                LevelMeter(level: model.level)
                    .frame(width: 42, height: 18)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 42)
            }
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 190, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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

import AppKit
import SwiftUI

/// A small floating pill at the bottom of the screen, in the spirit of Wispr Flow: it appears
/// over everything, never takes focus, and fades away on its own unless the pointer is on it.
struct Toast {
    enum Style { case info, warning, error }

    /// Repeats of one id within `minimumInterval` are dropped.
    var id: String
    var symbol: String
    var title: String
    var detail: String?
    var style: Style = .info
    var actions: [ToastAction] = []
    var duration: TimeInterval = 5
    var minimumInterval: TimeInterval = 120
}

struct ToastAction {
    var title: String
    var perform: @MainActor () -> Void
}

@MainActor final class Toaster {
    static let shared = Toaster()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var lastShown: [String: Date] = [:]
    private var current: Toast?
    /// When the notice goes, unless the pointer is on it.
    private var hideAt = Date.distantFuture

    /// The shortest time any notice stays up, so there's time to read it.
    private static let minimumDuration: TimeInterval = 6
    /// How long a notice stays after the pointer leaves it.
    private static let linger: TimeInterval = 2.5

    func show(_ toast: Toast) {
        let now = Date()
        if let panel, panel.isVisible, current?.id == toast.id, toast.minimumInterval > 0 {
            // Already on screen: keep it up a little longer rather than flash it again.
            scheduleHide(after: toast.duration)
            return
        }
        if let last = lastShown[toast.id], now.timeIntervalSince(last) < toast.minimumInterval { return }
        lastShown[toast.id] = now
        current = toast
        Log.info("Notice: \(toast.title)\(toast.detail.map { " — \($0)" } ?? "")")

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: ToastView(toast: toast, onDismiss: { [weak self] in self?.dismiss() }))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let target = NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 12, width: size.width, height: size.height)
        if !panel.isVisible {
            panel.setFrame(target.offsetBy(dx: 0, dy: -10), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        scheduleHide(after: toast.duration)
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        current = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if self.current == nil { panel.orderOut(nil) }
            }
        })
    }

    /// Hides the notice after `seconds`, but never while the pointer is on it: it stays as long
    /// as you hover and goes a little after you move away. The pointer is watched directly,
    /// because a panel in a background app gets no hover events.
    private func scheduleHide(after seconds: TimeInterval) {
        hideAt = Date().addingTimeInterval(max(seconds, Self.minimumDuration))
        guard hideTask == nil else { return }
        hideTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.pointerIsOnPanel {
                    self.hideAt = max(self.hideAt, Date().addingTimeInterval(Self.linger))
                } else if Date() >= self.hideAt {
                    self.dismiss()
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private var pointerIsOnPanel: Bool {
        guard let panel, panel.isVisible else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        return panel
    }
}

private struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    private var accent: Color {
        switch toast.style {
        case .info: return Color(red: 0.98, green: 0.36, blue: 0.47)
        case .warning: return Color(red: 1.0, green: 0.74, blue: 0.27)
        case .error: return Color(red: 1.0, green: 0.42, blue: 0.38)
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: toast.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 340, alignment: .leading)
            ForEach(Array(toast.actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) {
                    action.perform()
                    onDismiss()
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, toast.actions.isEmpty ? 16 : 9)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color(white: 0.07).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.24 : 0.14)))
    }
}

import AppKit
import SwiftUI

/// The frosted backdrop behind the whole workspace.
///
/// `behindWindow` blending is what makes the desktop show through and blur;
/// without it the window would just be a flat dark rectangle. The view sits at
/// the very back of the hierarchy and everything else draws over it with a
/// partly transparent tint.
struct VisualEffectBackground: NSViewRepresentable {
    var isEnabled: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // A light material on purpose: the workspace paints its own dark tint
        // on top, and a heavy material like .underPageBackground would darken
        // things twice over and swallow the blur entirely.
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // Keep frosting even when the window is not focused; a terminal that
        // goes flat the moment you click away reads as a bug.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = isEnabled ? .active : .inactive
        view.isHidden = !isEnabled
    }
}

/// Makes the host `NSWindow` non-opaque so the backdrop can show through.
///
/// AppKit only composites transparency if the window itself opts out of being
/// opaque, which SwiftUI gives no direct control over — hence this zero-sized
/// view that reaches up to the window once it is attached.
struct WindowConfigurator: NSViewRepresentable {
    var isTranslucent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        window.isOpaque = !isTranslucent
        window.backgroundColor = isTranslucent ? .clear : .windowBackgroundColor
        window.titlebarAppearsTransparent = isTranslucent

        // SwiftUI installs its own opaque backing on the content view, which
        // would sit in front of the window's clear background and block the
        // desktop no matter what the window itself is set to.
        if isTranslucent {
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// The frosted desktop plus the single dark tint that sits over it.
///
/// Everything the workspace draws goes on top of this and must stay clear or
/// near-clear. Translucent fills compound — two layers at 85% leave only ~2% of
/// the desktop showing, which reads as a completely opaque window — so this is
/// the *only* place the window's darkness comes from.
struct WindowBackdrop: View {
    var opacity: Double
    var blurred: Bool

    private var isTranslucent: Bool { opacity < 0.99 }

    var body: some View {
        ZStack {
            if isTranslucent {
                VisualEffectBackground(isEnabled: blurred)
                Surface.tint(opacity)
            } else {
                Surface.tint(1)
            }
            WindowConfigurator(isTranslucent: isTranslucent)
        }
        .ignoresSafeArea()
    }
}

/// Shared surface colors.
///
/// Only `tint` is allowed to be substantially opaque. The rest lighten what is
/// already there by a few percent, so no matter how many of them overlap the
/// desktop keeps showing through at the level the user asked for.
enum Surface {
    /// The one dark layer over the blur. Its alpha *is* the window opacity.
    static func tint(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(calibratedWhite: 0.055, alpha: opacity))
    }

    /// The terminal adds nothing of its own — the backdrop already provides the
    /// darkness, and painting again here is what made the window opaque.
    static func terminal(_ opacity: Double) -> NSColor {
        opacity < 0.99 ? .clear : NSColor(calibratedWhite: 0.055, alpha: 1)
    }

    /// Chrome (toolbars, sidebar, status bar) lifts slightly off the terminal
    /// rather than laying down another dark sheet.
    static var chrome: Color { Color.white.opacity(0.04) }
}

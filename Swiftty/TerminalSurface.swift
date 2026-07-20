import AppKit
import ObjectiveC
import SwiftTerm
import SwiftUI

final class SwifttyTerminalView: LocalProcessTerminalView {
  var onClick: (() -> Void)?
  var onSelectionChanged: (() -> Void)?

  /// Computes the cell height from the terminal font metrics so the host
  /// can build accurate content-based frame sizes.
  var cellHeight: CGFloat {
    let f = font as CTFont
    let h = ceil((CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * lineSpacing)
    return max(h, 1)
  }

  override init(frame frameRect: NSRect) {
    _ = TerminalView.swizzleScrollWheel
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    _ = TerminalView.swizzleScrollWheel
    super.init(coder: coder)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      window.makeFirstResponder(self)
    }
  }

  private var scrollerObserver: NSKeyValueObservation?

  override func addSubview(_ view: NSView) {
    super.addSubview(view)
    setupScrollerObserver(view)
  }

  override func addSubview(_ view: NSView, positioned place: NSWindow.OrderingMode, relativeTo otherView: NSView?) {
    super.addSubview(view, positioned: place, relativeTo: otherView)
    setupScrollerObserver(view)
  }

  private func setupScrollerObserver(_ view: NSView) {
    if let scroller = view as? NSScroller {
      scroller.isHidden = true
      scrollerObserver = scroller.observe(\.isHidden, options: [.new]) { scroller, change in
        if change.newValue == false {
          scroller.isHidden = true
        }
      }
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onClick?()
    super.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    super.mouseUp(with: event)
    if selectionActive {
      onSelectionChanged?()
    }
  }
}

extension TerminalView {
  static let swizzleScrollWheel: Void = {
    let originalSelector = #selector(scrollWheel(with:))
    let swizzledSelector = #selector(swizzled_scrollWheel(with:))

    guard let originalMethod = class_getInstanceMethod(TerminalView.self, originalSelector),
      let swizzledMethod = class_getInstanceMethod(TerminalView.self, swizzledSelector)
    else {
      return
    }

    method_exchangeImplementations(originalMethod, swizzledMethod)
  }()

  @objc func swizzled_scrollWheel(with event: NSEvent) {
    if let next = nextResponder {
      next.scrollWheel(with: event)
    } else {
      swizzled_scrollWheel(with: event)
    }
  }
}

@MainActor
final class TerminalHandle {
  weak var view: SwifttyTerminalView?

  func send(_ text: String) {
    guard let view else { return }
    let bytes = Array(text.utf8)
    view.process.send(data: bytes[...])
    view.window?.makeFirstResponder(view)
  }

  func focus() {
    guard let view else { return }
    view.window?.makeFirstResponder(view)
  }
}

class FlippedContainerView: NSView {
  override var isFlipped: Bool { true }
}

struct TerminalSurface: NSViewRepresentable {
  typealias NSViewType = NSView

  let terminalView: SwifttyTerminalView
  let session: TerminalSession
  let onClick: (() -> Void)?
  let onSelectionChanged: (() -> Void)?

  func makeNSView(context: Context) -> NSView {
    let container = FlippedContainerView(frame: .zero)
    
    // Ensure the terminal view is detached from any previous parent container
    terminalView.removeFromSuperview()
    
    terminalView.onClick = onClick
    terminalView.onSelectionChanged = onSelectionChanged
    
    container.addSubview(terminalView)
    
    // Defer pending command execution until after layout/resize pass has settled in the window
    DispatchQueue.main.async {
      if let cmd = session.pendingCommand {
        session.pendingCommand = nil
        terminalView.send(txt: cmd + "\n")
      }
    }
    
    return container
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let terminalView = nsView.subviews.first as? SwifttyTerminalView else { return }
    let ch = terminalView.cellHeight
    let minHeight = 24 * ch
    let targetHeight = max(minHeight, nsView.bounds.height)
    terminalView.frame = NSRect(
      x: 0,
      y: 0,
      width: nsView.bounds.width,
      height: targetHeight
    )
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
    if let terminalView = nsView.subviews.first as? SwifttyTerminalView {
      terminalView.removeFromSuperview()
    }
  }
}

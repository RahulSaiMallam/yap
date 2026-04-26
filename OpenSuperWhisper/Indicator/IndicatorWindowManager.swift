import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
class IndicatorWindowManager: IndicatorViewDelegate {
    static let shared = IndicatorWindowManager()
    
    var window: NSWindow?
    var viewModel: IndicatorViewModel?
    
    private init() {}
    
    func show(nearPoint point: NSPoint? = nil) -> IndicatorViewModel {
        
        KeyboardShortcuts.enable(.escape)
        
        // Create new view model
        let newViewModel = IndicatorViewModel()
        newViewModel.delegate = self
        viewModel = newViewModel
        
        if window == nil {
            // Create window if it doesn't exist - using NSPanel for full-screen compatibility
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            
            self.window = panel
        }
        
        // Pick the screen the user is currently on (the one containing the
        // caret / cursor / frontmost window), then anchor at bottom-center
        // of that screen — WisprFlow-style fixed position. The cursor's
        // location is used only to disambiguate the multi-monitor case.
        let targetScreen = point.flatMap { FocusUtils.screenContaining(point: $0) } ?? NSScreen.main
        if let window = window, let screen = targetScreen {
            // Set content view first so the hosting view's intrinsic size
            // can be measured. The pre-allocated NSPanel size is ignored.
            let hostingView = NSHostingView(rootView: IndicatorWindow(viewModel: newViewModel))
            window.contentView = hostingView
            let fitting = hostingView.fittingSize
            let contentSize = NSSize(
                width: max(fitting.width, 80),
                height: max(fitting.height, 30)
            )
            window.setContentSize(contentSize)

            // Now position using the actual window size on the visible
            // frame (excludes Dock and menu bar), bottom-center, ~70 pt
            // above the bottom edge of the working area.
            let visibleFrame = screen.visibleFrame
            let windowFrame = window.frame
            var x = visibleFrame.midX - windowFrame.width / 2
            var y = visibleFrame.minY + 70

            x = max(visibleFrame.minX, min(x, visibleFrame.maxX - windowFrame.width))
            y = max(visibleFrame.minY, min(y, visibleFrame.maxY - windowFrame.height))

            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        window?.orderFront(nil)
        return newViewModel
    }
    
    func stopRecording() {
        viewModel?.startDecoding()
    }
    
    func stopForce() {
        viewModel?.cancelRecording()
        viewModel?.cleanup()
        hide()
    }

    func hide() {
        KeyboardShortcuts.disable(.escape)
        
        Task {
            guard let viewModel = self.viewModel else { return }
            
            await viewModel.hideWithAnimation()
            viewModel.cleanup()
            
            self.window?.contentView = nil
            self.window?.orderOut(nil)
            self.viewModel = nil
            
            NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        }
    }
    
    func didFinishDecoding() {
        hide()
    }
}

import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", default: .init(.escape))
}

class ShortcutManager {
    static let shared = ShortcutManager()

    /// Captured at the moment the hotkey is pressed, before the indicator
    /// window steals focus. Read by the transcription-completion path to
    /// decide between auto-paste (text field was focused) and notify-only
    /// (focus was on Finder, menu bar, etc.).
    @MainActor static var hotkeyPressedInTextField: Bool = false

    /// Captured alongside `hotkeyPressedInTextField`: true when focus was
    /// on a known chat / messaging app at hotkey-press time. Drives the
    /// optional auto-submit (synthetic Return after paste) behavior.
    @MainActor static var hotkeyPressedInChatApp: Bool = false

    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false
    private var useModifierOnlyHotkey = false

    private init() {
        print("ShortcutManager init")
        
        setupKeyboardShortcuts()
        setupModifierKeyMonitor()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
    }
    
    @objc private func hotkeySettingsChanged() {
        setupModifierKeyMonitor()
    }
    
    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            Task { @MainActor in
                if self?.activeVm != nil {
                    IndicatorWindowManager.shared.stopForce()
                    self?.activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.escape)
    }
    
    private func setupModifierKeyMonitor() {
        let modifierKeyString = AppPreferences.shared.modifierOnlyHotkey
        let modifierKey = ModifierKey(rawValue: modifierKeyString) ?? .none
        
        if modifierKey != .none {
            useModifierOnlyHotkey = true
            KeyboardShortcuts.disable(.toggleRecord)
            
            ModifierKeyMonitor.shared.onKeyDown = { [weak self] in
                self?.handleKeyDown()
            }
            
            ModifierKeyMonitor.shared.onKeyUp = { [weak self] in
                self?.handleKeyUp()
            }
            
            ModifierKeyMonitor.shared.start(modifierKey: modifierKey)
            print("ShortcutManager: Using modifier-only hotkey: \(modifierKey.displayName)")
        } else {
            useModifierOnlyHotkey = false
            ModifierKeyMonitor.shared.stop()
            KeyboardShortcuts.enable(.toggleRecord)
            print("ShortcutManager: Using regular keyboard shortcut")
        }
    }
    
    private func handleKeyDown() {
        holdWorkItem?.cancel()
        holdMode = false
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if self.activeVm == nil {
                let cursorPosition = FocusUtils.getCurrentCursorPosition()
                let bundleID = FocusUtils.currentFocusedBundleID()
                ShortcutManager.hotkeyPressedInTextField = FocusUtils.isLikelyTextDestination(bundleID: bundleID)
                ShortcutManager.hotkeyPressedInChatApp = FocusUtils.isChatApp(bundleID: bundleID)
                DiagLog.write("handleKeyDown bundleID=\(bundleID ?? "nil") textField=\(ShortcutManager.hotkeyPressedInTextField) chatApp=\(ShortcutManager.hotkeyPressedInChatApp) trusted=\(AXIsProcessTrusted())")
                let indicatorPoint: NSPoint?
                if let caret = FocusUtils.getCaretRect() {
                    indicatorPoint = FocusUtils.convertAXPointToCocoa(caret.origin)
                } else {
                    indicatorPoint = cursorPosition
                }
                let vm = IndicatorWindowManager.shared.show(nearPoint: indicatorPoint)
                vm.startRecording()
                self.activeVm = vm
            } else if !self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
        }
        
        if holdToRecordEnabled {
            let workItem = DispatchWorkItem { [weak self] in
                self?.holdMode = true
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }
    
    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if holdToRecordEnabled && self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.holdMode = false
            }
        }
    }
}

/// Append-only diagnostic logger that writes to /tmp/osw-diag.log so logs
/// are readable from outside the app regardless of how it was launched.
/// `print()` only reaches stdout, which is invisible when the app is
/// launched via launch services. Remove once auto-submit is verified.
enum DiagLog {
    private static let logURL = URL(fileURLWithPath: "/tmp/osw-diag.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
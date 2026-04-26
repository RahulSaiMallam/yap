//
//  FocusUtils.swift
//  OpenSuperWhisper
//
//  Created by user on 07.02.2025.
//

import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

class FocusUtils {
    
    static func getCurrentCursorPosition() -> NSPoint {
        return NSEvent.mouseLocation
    }

    /// Bundle IDs known to NOT accept pasted text (Finder, our own indicator).
    /// Positive AX role detection is unreliable across Electron apps and
    /// contenteditable web inputs, so we use a small negative list and
    /// default to "yes, paste here" for everything else.
    static let nonTextDestinations: Set<String> = [
        "com.apple.finder",
        "app.yap.dictation",
    ]

    /// Bundle IDs of chat / messaging apps where pressing Enter sends a
    /// message. Used by the auto-submit feature.
    static let chatApps: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.openai.chat",
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS",
        "com.hnc.Discord",
        "com.microsoft.teams2",
        "com.tdesktop.Telegram",
        "WhatsApp",
        "net.whatsapp.WhatsApp",
    ]

    /// Bundle ID of the currently frontmost application. Uses NSWorkspace
    /// because the AX-based equivalent (`kAXFocusedApplicationAttribute` on
    /// the system-wide element) silently returns nil on macOS 26 even when
    /// the process is AX-trusted.
    static func currentFocusedBundleID() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func isLikelyTextDestination(bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !nonTextDestinations.contains(bundleID)
    }

    static func isChatApp(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chatApps.contains(bundleID)
    }

    static func getCaretRect() -> CGRect? {
        // Получаем системный элемент для доступа ко всему UI
        let systemElement = AXUIElementCreateSystemWide()
        
        // Получаем фокусированный элемент
        var focusedElement: CFTypeRef? // Keep as CFTypeRef? if you prefer
        let errorFocused = AXUIElementCopyAttributeValue(systemElement,
                                                         kAXFocusedUIElementAttribute as CFString,
                                                         &focusedElement)
        
        print("errorFocused: \(errorFocused)")
        guard errorFocused == .success else {
            print("Не удалось получить фокусированный элемент")
            return nil
        }
        
        guard let focusedElementCF = focusedElement else { // Optional binding to safely unwrap CFTypeRef
            print("Не удалось получить фокусированный элемент (CFTypeRef is nil)") // Extra safety check, though unlikely
            return nil
        }
        
        let element = focusedElementCF as! AXUIElement
        // Получаем выделенный текстовый диапазон у фокусированного элемента
        var selectedTextRange: AnyObject?
        let errorRange = AXUIElementCopyAttributeValue(element,
                                                       kAXSelectedTextRangeAttribute as CFString,
                                                       &selectedTextRange)
        guard errorRange == .success,
              let textRange = selectedTextRange
        else {
            print("Не удалось получить диапазон выделенного текста")
            return nil
        }
        
        // Используем параметризованный атрибут для получения границ диапазона (положение каретки)
        var caretBounds: CFTypeRef?
        let errorBounds = AXUIElementCopyParameterizedAttributeValue(element,
                                                                     kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                     textRange,
                                                                     &caretBounds)
        
        print("errorbounds: \(errorBounds), caretBounds \(String(describing: caretBounds))")
        guard errorBounds == .success else {
            print("Не удалось получить границы каретки")
            return nil
        }
        
        let rect = caretBounds as! AXValue
        
        return rect.toCGRect()
    }
    
    /// Converts a point from AX API coordinate system (Quartz: origin at top-left of primary screen, Y increases downward)
    /// to Cocoa coordinate system (origin at bottom-left of primary screen, Y increases upward)
    static func convertAXPointToCocoa(_ axPoint: CGPoint) -> NSPoint {
        guard let primaryScreen = NSScreen.screens.first else {
            return NSPoint(x: axPoint.x, y: axPoint.y)
        }
        // Primary screen maxY represents the total height in Cocoa coordinates
        // AX Y=0 is at Cocoa Y=maxY, so we subtract axPoint.y from maxY
        let cocoaY = primaryScreen.frame.maxY - axPoint.y
        return NSPoint(x: axPoint.x, y: cocoaY)
    }
    
    /// Finds the screen that contains the given point (in Cocoa coordinates)
    static func screenContaining(point: NSPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }
        return NSScreen.main
    }
    
    static func getFocusedWindowScreen() -> NSScreen? {
        let systemWideElement = AXUIElementCreateSystemWide()
        
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement,
                                                   kAXFocusedWindowAttribute as CFString,
                                                   &focusedWindow)
        
        guard result == .success else {
            print("Не удалось получить сфокусированное окно")
            return NSScreen.main
        }
        let windowElement = focusedWindow as! AXUIElement
        
        var windowFrameValue: CFTypeRef?
        let frameResult = AXUIElementCopyAttributeValue(windowElement,
                                                        
                                                        "AXFrame" as CFString,
                                                        &windowFrameValue)
        
        guard frameResult == .success else {
            print("Не удалось получить фрейм окна")
            return NSScreen.main
        }
        let frameValue = windowFrameValue as! AXValue
        
        var windowFrame = CGRect.zero
        guard AXValueGetValue(frameValue, AXValueType.cgRect, &windowFrame) else {
            print("Не удалось извлечь CGRect из AXValue")
            return NSScreen.main
        }
        
        for screen in NSScreen.screens {
            if screen.frame.intersects(windowFrame) {
                return screen
            }
        }
        
        return NSScreen.main
    }

}

private extension AXValue {
    func toCGRect() -> CGRect? {
        var rect = CGRect.zero
        let type: AXValueType = AXValueGetType(self)
        
        guard type == .cgRect else {
            print("AXValue is not of type CGRect, but \(type)") // More informative error
            return nil
        }
        
        let success = AXValueGetValue(self, .cgRect, &rect)
        
        guard success else {
            print("Failed to get CGRect value from AXValue")
            return nil
        }
        return rect
    }
}

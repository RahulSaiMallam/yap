import Cocoa
import ApplicationServices
import Carbon

class ClipboardUtil {

    static func insertText(_ text: String) {
        copyToClipboard(text)
        simulatePaste()
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }
    
    private static func simulatePaste() {
        sendCmdV()
    }

    /// Posts a synthetic Return-key press. Used by the auto-submit feature
    /// after dictation pastes into a chat app.
    static func simulateReturn() {
        let keyCodeReturn: CGKeyCode = 36
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: false)
        else { return }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
    
    private static func sendCmdV() {
        // QWERTY keycode for V
        let qwertyKeyCodeV: CGKeyCode = 9
        
        // Determine the correct keycode for Cmd+V
        let keyCodeV: CGKeyCode
        
        if isQwertyCommandLayout() {
            // For layouts like "Dvorak - QWERTY ⌘" that use QWERTY for Command shortcuts
            keyCodeV = qwertyKeyCodeV
        } else if let foundKeycode = findKeycodeForCharacter("v") {
            // For layouts where shortcuts follow the layout (Dvorak Left/Right Hand)
            keyCodeV = foundKeycode
        } else {
            // Fallback for non-Latin layouts (Russian, etc.) - use QWERTY keycode
            keyCodeV = qwertyKeyCodeV
        }
        
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else { return }
        
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
    
    static func isQwertyCommandLayout() -> Bool {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return false }
        
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        
        // "Dvorak - QWERTY ⌘" uses QWERTY positions for Command shortcuts
        // Its ID contains "DVORAK-QWERTY" or similar patterns
        // Also standard QWERTY, ABC, US layouts use keycode 9 for V
        let qwertyCommandLayouts = [
            "DVORAK-QWERTY",  // Dvorak - QWERTY ⌘
            "US",             // US QWERTY
            "ABC",            // ABC
            "Australian",     // Australian
            "British",        // British
            "Canadian",       // Canadian
            "USInternational" // US International
        ]
        
        let upperID = sourceID.uppercased()
        return qwertyCommandLayouts.contains { upperID.contains($0.uppercased()) }
    }
    
    static func findKeycodeForCharacter(_ char: Character) -> CGKeyCode? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        
        let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )
        
        let targetLower = char.lowercased()
        
        // Iterate through common keycodes (0-50 covers all letter keys)
        for keycode: UInt16 in 0...50 {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            
            let status = UCKeyTranslate(
                keyboardLayout,
                keycode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
            
            if status == noErr && length > 0 {
                let resultChar = Character(UnicodeScalar(chars[0])!)
                if resultChar.lowercased() == targetLower {
                    return CGKeyCode(keycode)
                }
            }
        }
        return nil
    }
    
    @available(*, deprecated, renamed: "insertText")
    static func insertTextUsingPasteboard(_ text: String) {
        insertText(text)
    }
    
    // MARK: - Testing Helpers
    
    static func getCurrentInputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }
    
    static func switchToInputSource(withID targetID: String) -> Bool {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            
            if sourceID.contains(targetID) || targetID.contains(sourceID) || sourceID == targetID {
                let result = TISSelectInputSource(source)
                usleep(100000) // 100ms delay for layout switch
                return result == noErr
            }
        }
        return false
    }
    
    static func getAvailableInputSources() -> [String] {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        
        var result: [String] = []
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let selectablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            else { continue }
            
            let isSelectable = unsafeBitCast(selectablePtr, to: CFBoolean.self) == kCFBooleanTrue
            if isSelectable {
                let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                result.append(sourceID)
            }
        }
        return result
    }
}

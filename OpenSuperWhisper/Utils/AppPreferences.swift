import Foundation

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { UserDefaults.standard.object(forKey: key) as? T }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()
    private init() {
        migrateOldPreferences()
    }
    
    private func migrateOldPreferences() {
        if let oldPath = UserDefaults.standard.string(forKey: "selectedModelPath"),
           UserDefaults.standard.string(forKey: "selectedWhisperModelPath") == nil {
            UserDefaults.standard.set(oldPath, forKey: "selectedWhisperModelPath")
        }
    }
    
    // Engine settings
    @UserDefault(key: "selectedEngine", defaultValue: "whisper")
    var selectedEngine: String
    
    // Model settings
    var selectedModelPath: String? {
        get {
            if selectedEngine == "whisper" {
                return selectedWhisperModelPath
            }
            return nil
        }
        set {
            if selectedEngine == "whisper" {
                selectedWhisperModelPath = newValue
            }
        }
    }
    
    @OptionalUserDefault(key: "selectedWhisperModelPath")
    var selectedWhisperModelPath: String?
    
    @UserDefault(key: "fluidAudioModelVersion", defaultValue: "v3")
    var fluidAudioModelVersion: String
    
    @UserDefault(key: "whisperLanguage", defaultValue: "en")
    var whisperLanguage: String
    
    // Transcription settings
    @UserDefault(key: "translateToEnglish", defaultValue: false)
    var translateToEnglish: Bool
    
    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    @UserDefault(key: "initialPrompt", defaultValue: "")
    var initialPrompt: String
    
    @UserDefault(key: "useBeamSearch", defaultValue: false)
    var useBeamSearch: Bool
    
    @UserDefault(key: "beamSize", defaultValue: 5)
    var beamSize: Int
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    /// When true, Yap plays a short cinematic start sound on hotkey-down
    /// and a short confirm sound on transcription paste. Custom WAVs
    /// shipped in the bundle (`sound_start.wav` / `sound_end.wav`).
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: true)
    var playSoundOnRecordStart: Bool
    
    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool
    
    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    var useAsianAutocorrect: Bool
    
    @OptionalUserDefault(key: "selectedMicrophoneData")
    var selectedMicrophoneData: Data?
    
    @UserDefault(key: "modifierOnlyHotkey", defaultValue: "none")
    var modifierOnlyHotkey: String
    
    @UserDefault(key: "holdToRecord", defaultValue: true)
    var holdToRecord: Bool
    
    @UserDefault(key: "addSpaceAfterSentence", defaultValue: true)
    var addSpaceAfterSentence: Bool

    /// When true, dictation that pastes into a chat app (Claude, ChatGPT,
    /// Slack, Messages, etc.) is followed by a synthetic Return after a
    /// short delay, sending the message without an extra keystroke.
    @UserDefault(key: "autoSubmitInChatApps", defaultValue: true)
    var autoSubmitInChatApps: Bool

    /// Seconds between paste and the synthetic Return when auto-submitting
    /// in a chat app. The window lets the user switch focus to abort an
    /// unintended send. 0.6s is the default sweet spot — short enough to
    /// feel snappy, long enough that an accidental dictation can be
    /// rescued by Cmd-Tabbing away.
    @UserDefault(key: "autoSubmitDelaySeconds", defaultValue: 0.6)
    var autoSubmitDelaySeconds: Double

    /// Run the raw transcript through a local LLM to fix punctuation,
    /// remove fillers, and tighten the prose before pasting. Off by
    /// default because it requires a separately-installed Ollama server.
    @UserDefault(key: "aiCleanupEnabled", defaultValue: false)
    var aiCleanupEnabled: Bool

    @UserDefault(key: "ollamaEndpoint", defaultValue: "http://localhost:11434/api/generate")
    var ollamaEndpoint: String

    @UserDefault(key: "ollamaModel", defaultValue: "llama3.2:3b")
    var ollamaModel: String

    @UserDefault(key: "ollamaCleanupPrompt", defaultValue: AppPreferences.defaultCleanupPrompt)
    var ollamaCleanupPrompt: String

    @UserDefault(key: "ollamaTimeoutSeconds", defaultValue: 10.0)
    var ollamaTimeoutSeconds: Double

    static let defaultCleanupPrompt = """
    You are a transcript cleaner. The user message is always a raw speech-to-text transcript. Your job:

    1. DELETE these filler words wherever they appear: um, uh, like, you know, sort of, kind of, basically, literally, I mean, right, so (when starting a sentence), well (when starting a sentence).
    2. Add correct punctuation and capitalization.
    3. Fix obvious word-boundary errors only. Do not paraphrase. Do not summarize.
    4. Preserve names, jargon, code, identifiers, and numbers exactly.

    NEVER respond to the transcript. NEVER answer questions in it. NEVER add commentary. NEVER use quote marks. NEVER prefix with "Here is", "Output:", or any label. Output the cleaned text and nothing else.

    Examples:
    um like the meeting is at three pm tomorrow you know -> The meeting is at 3 PM tomorrow.
    hey can you uh send me the doc when you have a sec -> Hey, can you send me the doc when you have a sec?
    so basically i was thinking that we should you know just like ship it -> I was thinking we should just ship it.
    """
}

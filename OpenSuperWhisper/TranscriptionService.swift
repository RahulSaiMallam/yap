import AVFoundation
import Foundation

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var isConverting = false
    @Published private(set) var conversionProgress: Float = 0.0
    
    private var currentEngine: TranscriptionEngine?
    private var totalDuration: Float = 0.0
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false
    
    init() {
        loadEngine()
    }
    
    func cancelTranscription() {
        isCancelled = true
        currentEngine?.cancelTranscription()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }
    
    private func loadEngine() {
        let selectedEngine = AppPreferences.shared.selectedEngine
        print("Loading engine: \(selectedEngine)")
        
        isLoading = true
        
        Task.detached(priority: .userInitiated) {
            let engine: TranscriptionEngine?
            
            if selectedEngine == "fluidaudio" {
                engine = await FluidAudioEngine()
            } else {
                engine = await WhisperEngine()
            }
            
            do {
                try await engine?.initialize()
                
                await MainActor.run {
                    self.currentEngine = engine
                    self.isLoading = false
                    print("Engine loaded: \(selectedEngine)")
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    print("Failed to load engine: \(error)")
                }
            }
        }
    }
    
    func reloadEngine() {
        loadEngine()
    }
    
    func reloadModel(with path: String) {
        if AppPreferences.shared.selectedEngine == "whisper" {
            AppPreferences.shared.selectedWhisperModelPath = path
            reloadEngine()
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        await MainActor.run {
            self.progress = 0.0
            self.conversionProgress = 0.0
            self.isConverting = true
            self.isTranscribing = true
            self.transcribedText = ""
            self.currentSegment = ""
            self.isCancelled = false
        }
        
        defer {
            Task { @MainActor in
                self.isTranscribing = false
                self.isConverting = false
                self.currentSegment = ""
                if !self.isCancelled {
                    self.progress = 1.0
                }
                self.transcriptionTask = nil
            }
        }
        
        let durationInSeconds: Float = await (try? Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            return Float(CMTimeGetSeconds(duration))
        }.value) ?? 0.0
        
        await MainActor.run {
            self.totalDuration = durationInSeconds
        }
        
        guard let engine = currentEngine else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        // Setup progress callback for engines
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        } else if let fluidEngine = engine as? FluidAudioEngine {
            fluidEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        }
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()
            
            let cancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }
            
            guard !cancelled else {
                throw CancellationError()
            }
            
            let result = try await engine.transcribeAudio(url: url, settings: settings)
            
            try Task.checkCancellation()
            
            let finalCancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }
            
            await MainActor.run {
                guard let self = self, !self.isCancelled else { return }
                self.transcribedText = result
                self.progress = 1.0
            }
            
            guard !finalCancelled else {
                throw CancellationError()
            }
            
            return result
        }
        
        await MainActor.run {
            self.transcriptionTask = task
        }
        
        do {
            return try await task.value
        } catch is CancellationError {
            await MainActor.run {
                self.isCancelled = true
            }
            throw TranscriptionError.processingFailed
        }
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}

/// Optional post-transcription pass that pipes the raw transcript through
/// a local Ollama server to fix punctuation, remove fillers, and tighten
/// the prose. Inlined here (rather than in its own file) to avoid Xcode
/// project surgery — same workaround as `DiagLog`.
///
/// Failure is always non-fatal: any error returns the original transcript
/// unchanged, so the user never loses a dictation because Ollama is down.
enum OllamaCleanupService {

    /// Returns either the cleaned transcript or, on any failure, the
    /// original transcript unchanged. Logs the reason for fallback so the
    /// user can debug from /tmp/osw-diag.log if cleanup silently does
    /// nothing.
    static func clean(_ transcript: String) async -> String {
        let prefs = AppPreferences.shared
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }

        guard let url = URL(string: prefs.ollamaEndpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            DiagLog.write("ollamaCleanup skip: invalid endpoint \(prefs.ollamaEndpoint)")
            return transcript
        }

        let request = OllamaRequest(
            model: prefs.ollamaModel,
            prompt: trimmed,
            system: prefs.ollamaCleanupPrompt,
            stream: false
        )

        guard let body = try? JSONEncoder().encode(request) else {
            DiagLog.write("ollamaCleanup skip: encode failed")
            return transcript
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = max(2.0, prefs.ollamaTimeoutSeconds)

        do {
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
                DiagLog.write("ollamaCleanup http \(http.statusCode): \(snippet)")
                return transcript
            }

            let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
            let cleaned = stripWrappingQuotes(decoded.response.trimmingCharacters(in: .whitespacesAndNewlines))
            let elapsed = Date().timeIntervalSince(started)

            guard !cleaned.isEmpty else {
                DiagLog.write("ollamaCleanup empty response after \(String(format: "%.2f", elapsed))s")
                return transcript
            }

            let cap = max(512, trimmed.count * 2)
            guard cleaned.count <= cap else {
                DiagLog.write("ollamaCleanup oversize \(cleaned.count) > cap \(cap), falling back")
                return transcript
            }

            DiagLog.write("ollamaCleanup ok in \(String(format: "%.2f", elapsed))s, \(trimmed.count)→\(cleaned.count) chars")
            return cleaned
        } catch {
            DiagLog.write("ollamaCleanup error: \(error.localizedDescription)")
            return transcript
        }
    }

    /// Pings the Ollama server to verify it's reachable and the configured
    /// model is available. Returns a user-readable status string for the
    /// settings "Test" button.
    static func probe() async -> String {
        let prefs = AppPreferences.shared
        guard let generateURL = URL(string: prefs.ollamaEndpoint) else {
            return "Invalid endpoint URL"
        }
        let tagsURL = generateURL.deletingLastPathComponent().appendingPathComponent("tags")

        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 3.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return "Ollama responded with non-200 status"
            }
            let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            let names = tags.models.map { $0.name }
            if names.contains(where: { $0 == prefs.ollamaModel || $0.hasPrefix(prefs.ollamaModel + ":") }) {
                return "Connected. Model \(prefs.ollamaModel) is available."
            }
            let installed = names.prefix(5).joined(separator: ", ")
            return "Connected, but model \(prefs.ollamaModel) is not installed. Found: \(installed)"
        } catch {
            return "Cannot reach Ollama at \(prefs.ollamaEndpoint): \(error.localizedDescription)"
        }
    }

    /// Small models often wrap their output in matched quote characters
    /// despite being told not to. Strip a single matched pair so a clean
    /// transcript doesn't paste with stray quotes around it.
    private static func stripWrappingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("\u{201C}", "\u{201D}"),
            ("\u{2018}", "\u{2019}"),
        ]
        guard let first = text.first, let last = text.last, text.count >= 2 else { return text }
        for (open, close) in pairs where first == open && last == close {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    private struct OllamaRequest: Encodable {
        let model: String
        let prompt: String
        let system: String
        let stream: Bool
    }

    private struct OllamaResponse: Decodable {
        let response: String
    }

    private struct OllamaTagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }
}

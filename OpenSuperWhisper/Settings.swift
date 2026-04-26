import AppKit
import Carbon
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI
import FluidAudio

class SettingsViewModel: ObservableObject {
    @Published var selectedEngine: String {
        didSet {
            AppPreferences.shared.selectedEngine = selectedEngine
            if selectedEngine == "whisper" {
                loadAvailableModels()
            } else {
                initializeFluidAudioModels()
            }
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
    }

    @Published var fluidAudioModelVersion: String {
        didSet {
            AppPreferences.shared.fluidAudioModelVersion = fluidAudioModelVersion
            if selectedEngine == "fluidaudio" {
                Task { @MainActor in
                    TranscriptionService.shared.reloadEngine()
                }
            }
            initializeFluidAudioModels()
        }
    }

    @Published var selectedModelURL: URL? {
        didSet {
            if let url = selectedModelURL {
                AppPreferences.shared.selectedWhisperModelPath = url.path
            }
        }
    }

    @Published var availableModels: [URL] = []

    @Published var downloadableModels: [SettingsDownloadableModel] = []
    @Published var downloadableFluidAudioModels: [SettingsFluidAudioModel] = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    private var downloadTask: Task<Void, Error>?

    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }

    @Published var translateToEnglish: Bool {
        didSet {
            AppPreferences.shared.translateToEnglish = translateToEnglish
        }
    }

    @Published var suppressBlankAudio: Bool {
        didSet {
            AppPreferences.shared.suppressBlankAudio = suppressBlankAudio
        }
    }

    @Published var showTimestamps: Bool {
        didSet {
            AppPreferences.shared.showTimestamps = showTimestamps
        }
    }

    @Published var temperature: Double {
        didSet {
            AppPreferences.shared.temperature = temperature
        }
    }

    @Published var noSpeechThreshold: Double {
        didSet {
            AppPreferences.shared.noSpeechThreshold = noSpeechThreshold
        }
    }

    @Published var initialPrompt: String {
        didSet {
            AppPreferences.shared.initialPrompt = initialPrompt
        }
    }

    @Published var useBeamSearch: Bool {
        didSet {
            AppPreferences.shared.useBeamSearch = useBeamSearch
        }
    }

    @Published var beamSize: Int {
        didSet {
            AppPreferences.shared.beamSize = beamSize
        }
    }

    @Published var debugMode: Bool {
        didSet {
            AppPreferences.shared.debugMode = debugMode
        }
    }

    @Published var playSoundOnRecordStart: Bool {
        didSet {
            AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart
        }
    }

    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }

    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var holdToRecord: Bool {
        didSet {
            AppPreferences.shared.holdToRecord = holdToRecord
        }
    }

    @Published var addSpaceAfterSentence: Bool {
        didSet {
            AppPreferences.shared.addSpaceAfterSentence = addSpaceAfterSentence
        }
    }

    @Published var autoSubmitInChatApps: Bool {
        didSet {
            AppPreferences.shared.autoSubmitInChatApps = autoSubmitInChatApps
        }
    }

    @Published var autoSubmitDelaySeconds: Double {
        didSet {
            AppPreferences.shared.autoSubmitDelaySeconds = autoSubmitDelaySeconds
        }
    }

    @Published var aiCleanupEnabled: Bool {
        didSet { AppPreferences.shared.aiCleanupEnabled = aiCleanupEnabled }
    }

    @Published var ollamaEndpoint: String {
        didSet { AppPreferences.shared.ollamaEndpoint = ollamaEndpoint }
    }

    @Published var ollamaModel: String {
        didSet { AppPreferences.shared.ollamaModel = ollamaModel }
    }

    @Published var ollamaCleanupPrompt: String {
        didSet { AppPreferences.shared.ollamaCleanupPrompt = ollamaCleanupPrompt }
    }

    @Published var ollamaTimeoutSeconds: Double {
        didSet { AppPreferences.shared.ollamaTimeoutSeconds = ollamaTimeoutSeconds }
    }

    @Published var cleanupProbeStatus: String = ""
    @Published var isProbingCleanup: Bool = false

    init() {
        let prefs = AppPreferences.shared
        self.selectedEngine = prefs.selectedEngine
        self.fluidAudioModelVersion = prefs.fluidAudioModelVersion
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.modifierOnlyHotkey = ModifierKey(rawValue: prefs.modifierOnlyHotkey) ?? .none
        self.holdToRecord = prefs.holdToRecord
        self.addSpaceAfterSentence = prefs.addSpaceAfterSentence
        self.autoSubmitInChatApps = prefs.autoSubmitInChatApps
        self.autoSubmitDelaySeconds = prefs.autoSubmitDelaySeconds
        self.aiCleanupEnabled = prefs.aiCleanupEnabled
        self.ollamaEndpoint = prefs.ollamaEndpoint
        self.ollamaModel = prefs.ollamaModel
        self.ollamaCleanupPrompt = prefs.ollamaCleanupPrompt
        self.ollamaTimeoutSeconds = prefs.ollamaTimeoutSeconds

        if let savedPath = prefs.selectedWhisperModelPath ?? prefs.selectedModelPath {
            self.selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
        initializeDownloadableModels()
        initializeFluidAudioModels()
    }

    func initializeFluidAudioModels() {
        downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: model.version)
            return updatedModel
        }
    }

    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }

    func initializeDownloadableModels() {
        let modelManager = WhisperModelManager.shared
        downloadableModels = SettingsDownloadableModels.availableModels.map { model in
            var updatedModel = model
            let filename = model.url.lastPathComponent
            updatedModel.isDownloaded = modelManager.isModelDownloaded(name: filename)
            return updatedModel
        }
    }

    func loadAvailableModels() {
        availableModels = WhisperModelManager.shared.getAvailableModels()
        if selectedModelURL == nil {
            selectedModelURL = availableModels.first
        }
        initializeDownloadableModels()
    }

    @MainActor
    func downloadModel(_ model: SettingsDownloadableModel) async throws {
        guard !isDownloading else { return }

        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0

        downloadTask = Task {
            do {
                let filename = model.url.lastPathComponent

                try await WhisperModelManager.shared.downloadModel(url: model.url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }

                        self.downloadProgress = progress
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.downloadableModels[index].isDownloaded = true
                            }
                        }
                    }
                }

                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = 0.0
                        }
                    }
                    return
                }

                await MainActor.run {
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].isDownloaded = true
                        downloadableModels[index].downloadProgress = 0.0
                    }
                    loadAvailableModels()
                    let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename).path
                    selectedModelURL = URL(fileURLWithPath: modelPath)
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0

                    Task { @MainActor in
                        TranscriptionService.shared.reloadModel(with: modelPath)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }

        try await downloadTask?.value
    }

    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if selectedEngine == "whisper", let model = downloadableModels.first(where: { $0.name == modelName }) {
                let filename = model.url.lastPathComponent
                WhisperModelManager.shared.cancelDownload(name: filename)
            }
            if let index = downloadableModels.firstIndex(where: { $0.name == modelName }) {
                downloadableModels[index].downloadProgress = 0.0
            }
            if let index = downloadableFluidAudioModels.firstIndex(where: { $0.name == modelName }) {
                downloadableFluidAudioModels[index].downloadProgress = 0.0
            }
        }
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }

    @MainActor
    func downloadFluidAudioModel(_ model: SettingsFluidAudioModel) async throws {
        guard !isDownloading else { return }

        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0

        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
            downloadableFluidAudioModels[index].downloadProgress = 0.0
        }

        var wasCancelled = false

        downloadTask = Task {
            do {
                let version: AsrModelVersion = model.version == "v2" ? .v2 : .v3

                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }

                let models = try await AsrModels.downloadAndLoad(version: version)

                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }

                let manager = AsrManager(config: .default)
                try await manager.initialize(models: models)

                await MainActor.run {
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].isDownloaded = true
                        downloadableFluidAudioModels[index].downloadProgress = 1.0
                    }
                    fluidAudioModelVersion = model.version
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 1.0

                    Task { @MainActor in
                        TranscriptionService.shared.reloadEngine()
                    }
                }
            } catch is CancellationError {
                wasCancelled = true
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }

        do {
            try await downloadTask?.value
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            if !wasCancelled {
                throw error
            }
        }
    }

    @MainActor
    func downloadFluidAudioModel() async throws {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        if let model = downloadableFluidAudioModels.first(where: { $0.version == versionString }) {
            try await downloadFluidAudioModel(model)
        }
    }
}

struct SettingsDownloadableModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let url: URL
    let size: Int
    let description: String
    var downloadProgress: Double = 0.0

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(size) * 1000000)
    }

    init(name: String, isDownloaded: Bool, url: URL, size: Int, description: String) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.description = description
    }
}

struct SettingsDownloadableModels {
    static let availableModels = [
        SettingsDownloadableModel(
            name: "Turbo V3 large",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1624,
            description: "High accuracy, best quality"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 medium",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
            size: 874,
            description: "Balanced speed and accuracy"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 small",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
            size: 574,
            description: "Fastest processing"
        )
    ]
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]

    var selectedLanguage: String
    var translateToEnglish: Bool
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool

    var isAsianLanguage: Bool {
        Settings.asianLanguages.contains(selectedLanguage)
    }

    var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }

    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
    }
}

// MARK: Glass card primitives

private struct GlassCard<Content: View>: View {
    var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
    }
}

private struct CardTitle: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(text)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundColor(.primary)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var help: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                .labelsHidden()
                .modifier(OptionalHelp(help: help))
        }
    }
}

private struct OptionalHelp: ViewModifier {
    let help: String?
    func body(content: Content) -> some View {
        if let help = help {
            content.help(help)
        } else {
            content
        }
    }
}

private struct InlineCode: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
    }
}

private struct PathRow: View {
    let title: String
    let path: String
    let openAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer()
                Button(action: openAction) {
                    Label("Open Folder", systemImage: "folder")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help("Open folder in Finder")
            }
            Text(path)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
        }
    }
}

// MARK: Sidebar tab model

private enum SettingsTab: String, CaseIterable, Identifiable {
    case shortcuts, model, transcription, cleanup, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortcuts: return "Shortcuts"
        case .model: return "Model"
        case .transcription: return "Transcription"
        case .cleanup: return "Cleanup"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .shortcuts: return "command"
        case .model: return "cpu"
        case .transcription: return "text.bubble"
        case .cleanup: return "wand.and.stars"
        case .advanced: return "gear"
        }
    }

    var subtitle: String {
        switch self {
        case .shortcuts: return "Hotkeys and recording behavior"
        case .model: return "Engine and downloaded models"
        case .transcription: return "Language and output options"
        case .cleanup: return "Local LLM post-processing"
        case .advanced: return "Decoding, parameters, debug"
        }
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @Environment(\.dismiss) var dismiss
    @State private var isRecordingNewShortcut = false
    @State private var selectedTab: SettingsTab = .shortcuts
    @State private var previousModelURL: URL?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 580)
        .background(Color.clear)
        .safeAreaInset(edge: .bottom) {
            footerBar
        }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            if viewModel.selectedEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.selectedEngine) { _, newEngine in
            if newEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.fluidAudioModelVersion) { _, _ in
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
        .onChange(of: viewModel.selectedModelURL) { _, newURL in
            if viewModel.selectedEngine == "whisper", let modelPath = newURL?.path {
                Task { @MainActor in
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Yap")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Settings")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarRow(for: tab)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.ultraThinMaterial)
    }

    private func sidebarRow(for tab: SettingsTab) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.callout)
                    .foregroundColor(.primary)
                Text(tab.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            switch selectedTab {
            case .shortcuts:
                shortcutSettings
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .model:
                modelSettings
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .transcription:
                transcriptionSettings
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .cleanup:
                cleanupSettings
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .advanced:
                advancedSettings
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Button("Done") {
                if viewModel.selectedEngine == "whisper" {
                    if viewModel.selectedModelURL != previousModelURL, let modelPath = viewModel.selectedModelURL?.path {
                        TranscriptionService.shared.reloadModel(with: modelPath)
                    }
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)

            Spacer()

            Link(destination: URL(string: "https://github.com/Starmel/OpenSuperWhisper")!) {
                HStack(spacing: 4) {
                    Image(systemName: "star")
                        .font(.system(size: 10))
                    Text("GitHub")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.white.opacity(0.06)),
            alignment: .top
        )
    }

    // MARK: Section content

    private var modelSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(text: "Speech Recognition Engine", icon: "waveform")

                        Picker("Engine", selection: $viewModel.selectedEngine) {
                            Text("Parakeet").tag("fluidaudio")
                            Text("Whisper").tag("whisper")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text(viewModel.selectedEngine == "whisper"
                             ? "Whisper runs locally with whisper.cpp. Best quality, broadest language support."
                             : "Parakeet (FluidAudio) runs locally with Apple Neural Engine. Lowest latency.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if viewModel.selectedEngine == "whisper" {
                    whisperModelCard
                } else {
                    parakeetModelCard
                }

                if viewModel.isDownloading {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                if viewModel.downloadProgress > 0 {
                                    ProgressView(value: viewModel.downloadProgress)
                                        .progressViewStyle(LinearProgressViewStyle())
                                } else {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                }
                                Spacer()
                                Button("Cancel") {
                                    viewModel.cancelDownload()
                                }
                                .buttonStyle(.bordered)
                            }
                            if let downloadingName = viewModel.downloadingModelName {
                                Text("Downloading: \(downloadingName)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                modelDirectoryCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var whisperModelCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(text: "Whisper Models", icon: "square.stack.3d.up")

                Text("Download a model to run Whisper locally. Larger models are more accurate; smaller models are faster.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($viewModel.downloadableModels) { $model in
                            ModelDownloadItemView(model: $model, viewModel: viewModel)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private var parakeetModelCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(text: "Parakeet Models", icon: "bolt.fill")

                Text("Pick a Parakeet release. v3 covers 25 languages; v2 is English-only with higher recall.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($viewModel.downloadableFluidAudioModels) { $model in
                            FluidAudioModelDownloadItemView(model: $model, viewModel: viewModel)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private var modelDirectoryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(text: "Models Directory", icon: "folder")

                if viewModel.selectedEngine == "whisper" {
                    PathRow(
                        title: "Whisper models live here:",
                        path: WhisperModelManager.shared.modelsDirectory.path,
                        openAction: {
                            NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                        }
                    )
                } else {
                    PathRow(
                        title: "Parakeet models live here:",
                        path: AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent().path,
                        openAction: {
                            let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
                            let parentDir = cacheDir.deletingLastPathComponent()
                            NSWorkspace.shared.open(parentDir)
                        }
                    )
                }
            }
        }
    }

    private var transcriptionSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(text: "Language", icon: "globe")

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Transcription language")
                                .font(.callout)
                            Picker("Language", selection: $viewModel.selectedLanguage) {
                                ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                                    Text(LanguageUtil.languageNames[code] ?? code)
                                        .tag(code)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Divider().opacity(0.4)

                        ToggleRow(
                            title: "Translate to English",
                            subtitle: "Whisper-only. Translates non-English audio into English.",
                            isOn: $viewModel.translateToEnglish
                        )

                        if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                            ToggleRow(
                                title: "Use Asian autocorrect",
                                subtitle: "Light cleanup for Chinese, Japanese, and Korean output.",
                                isOn: $viewModel.useAsianAutocorrect
                            )
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(text: "Output", icon: "text.alignleft")

                        ToggleRow(title: "Show timestamps", isOn: $viewModel.showTimestamps)
                        ToggleRow(title: "Suppress blank audio", isOn: $viewModel.suppressBlankAudio)
                        ToggleRow(
                            title: "Add space after sentence",
                            subtitle: "Appends a space when the transcript ends with punctuation.",
                            isOn: $viewModel.addSpaceAfterSentence
                        )
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        CardTitle(text: "Custom Vocabulary", icon: "character.book.closed")

                        TextEditor(text: $viewModel.initialPrompt)
                            .font(.system(.callout))
                            .frame(minHeight: 88)
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                            )

                        Text("Names, jargon, or project terms that Whisper should recognize. Example: \"Anthropic, Kubernetes, Postgres, GraphQL\". Only applies to the Whisper engine.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(text: "Transcriptions Directory", icon: "tray.full")
                        PathRow(
                            title: "Saved transcripts and audio:",
                            path: Recording.recordingsDirectory.path,
                            openAction: {
                                NSWorkspace.shared.open(Recording.recordingsDirectory)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var advancedSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(text: "Decoding Strategy", icon: "function")

                        ToggleRow(
                            title: "Use beam search",
                            subtitle: "Slower but typically higher quality.",
                            help: "Beam search can provide better results but is slower",
                            isOn: $viewModel.useBeamSearch
                        )

                        if viewModel.useBeamSearch {
                            HStack {
                                Text("Beam size")
                                    .font(.callout)
                                Spacer()
                                Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
                                    .help("Number of beams to use in beam search")
                                    .frame(width: 130)
                            }
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 18) {
                        CardTitle(text: "Model Parameters", icon: "slider.horizontal.3")

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Temperature")
                                    .font(.callout)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.temperature))
                                    .font(.callout.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                                .tint(Color.accentColor)
                                .help("Higher values make the output more random")
                            Text("Higher values produce more varied output. 0.0 is deterministic.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("No-speech threshold")
                                    .font(.callout)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.noSpeechThreshold))
                                    .font(.callout.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $viewModel.noSpeechThreshold, in: 0.0...1.0, step: 0.1)
                                .tint(Color.accentColor)
                                .help("Threshold for detecting speech vs. silence")
                            Text("Threshold for detecting speech vs. silence in the audio.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(text: "Debug", icon: "ladybug")

                        ToggleRow(
                            title: "Debug mode",
                            subtitle: "Enables verbose logging and diagnostic UI.",
                            help: "Enable additional logging and debugging information",
                            isOn: $viewModel.debugMode
                        )
                    }
                }

                attributionBar
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var attributionBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.text.square")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
            Text("Built on OpenSuperWhisper by Starmel")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
            Text("·")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.5))
            Text("MIT")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var useModifierKey: Bool {
        viewModel.modifierOnlyHotkey != .none
    }

    private var shortcutSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CardTitle(text: "Recording Trigger", icon: "command")

                        Picker("", selection: Binding(
                            get: { useModifierKey },
                            set: { newValue in
                                if !newValue {
                                    viewModel.modifierOnlyHotkey = .none
                                } else if viewModel.modifierOnlyHotkey == .none {
                                    viewModel.modifierOnlyHotkey = .leftCommand
                                }
                            }
                        )) {
                            Text("Key Combination").tag(false)
                            Text("Single Modifier Key").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if useModifierKey {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Modifier key")
                                        .font(.callout)
                                    Spacer()
                                    Picker("", selection: $viewModel.modifierOnlyHotkey) {
                                        ForEach(ModifierKey.allCases.filter { $0 != .none }) { key in
                                            Text(key.displayName).tag(key)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(width: 200)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                )

                                Text("One tap to toggle recording.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Shortcut")
                                        .font(.callout)
                                    Spacer()
                                    KeyboardShortcuts.Recorder("", name: .toggleRecord)
                                        .frame(width: 160)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                )

                                if isRecordingNewShortcut {
                                    Text("Press your new shortcut combination...")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(text: "Recording Behavior", icon: "mic")

                        ToggleRow(
                            title: "Hold to record",
                            subtitle: "Hold the shortcut to record, release to stop.",
                            isOn: $viewModel.holdToRecord
                        )
                        ToggleRow(
                            title: "Play sound when recording starts",
                            help: "Play a notification sound when recording begins",
                            isOn: $viewModel.playSoundOnRecordStart
                        )
                        ToggleRow(
                            title: "Auto-submit in chat apps",
                            subtitle: "After paste, press Return automatically in Claude, ChatGPT, Slack, Messages, etc.",
                            isOn: $viewModel.autoSubmitInChatApps
                        )
                        if viewModel.autoSubmitInChatApps {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Auto-submit delay")
                                        .font(.subheadline)
                                    Spacer()
                                    Text(String(format: "%.1f s", viewModel.autoSubmitDelaySeconds))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: $viewModel.autoSubmitDelaySeconds, in: 0.2...3.0, step: 0.1)
                                Text("Window between paste and Return. Shorter feels snappier; longer gives you a chance to Cmd-Tab away to abort an unintended send.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var cleanupSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                CardTitle(text: "AI Cleanup", icon: "wand.and.stars")
                                Text("Run each transcript through a local LLM to fix punctuation, remove fillers, and tighten the prose.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.aiCleanupEnabled)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        if viewModel.aiCleanupEnabled {
                            Text("Requires Ollama running locally. Install with `brew install ollama`, then pull the model:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                InlineCode(text: "ollama pull \(viewModel.ollamaModel)")
                                Button {
                                    NSPasteboard.general.declareTypes([.string], owner: nil)
                                    NSPasteboard.general.setString("ollama pull \(viewModel.ollamaModel)", forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("Copy command")
                                Spacer()
                            }
                        }
                    }
                }

                if viewModel.aiCleanupEnabled {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 16) {
                            CardTitle(text: "Server", icon: "server.rack")

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Endpoint")
                                    .font(.callout)
                                TextField("http://localhost:11434/api/generate", text: $viewModel.ollamaEndpoint)
                                    .textFieldStyle(.roundedBorder)
                                Text("Ollama's /api/generate URL. Change only if Ollama runs on a different host or port.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model")
                                    .font(.callout)
                                TextField("gemma3:1b", text: $viewModel.ollamaModel)
                                    .textFieldStyle(.roundedBorder)
                                Text("Smaller models (gemma3:1b, llama3.2:1b) keep latency under ~500 ms. Larger models cost more wait per dictation.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Timeout")
                                        .font(.callout)
                                    Spacer()
                                    Text("\(Int(viewModel.ollamaTimeoutSeconds)) s")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: $viewModel.ollamaTimeoutSeconds, in: 2...30, step: 1)
                                    .tint(Color.accentColor)
                                Text("If Ollama doesn't respond within this window, the raw transcript is pasted instead.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            HStack {
                                Button {
                                    runCleanupProbe()
                                } label: {
                                    HStack(spacing: 6) {
                                        if viewModel.isProbingCleanup {
                                            ProgressView().scaleEffect(0.6)
                                        }
                                        Text("Test connection")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isProbingCleanup)
                                Spacer()
                            }

                            if !viewModel.cleanupProbeStatus.isEmpty {
                                Text(viewModel.cleanupProbeStatus)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                    )
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                CardTitle(text: "Cleanup Prompt", icon: "text.append")
                                Spacer()
                                Button("Reset to default") {
                                    viewModel.ollamaCleanupPrompt = AppPreferences.defaultCleanupPrompt
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }

                            TextEditor(text: $viewModel.ollamaCleanupPrompt)
                                .frame(minHeight: 200)
                                .font(.system(.body, design: .monospaced))
                                .padding(8)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                )

                            Text("Sent as the system prompt for each cleanup call. The transcript is passed as the user prompt. Keep it short — every token is latency.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private func runCleanupProbe() {
        viewModel.isProbingCleanup = true
        viewModel.cleanupProbeStatus = ""
        Task { @MainActor in
            let status = await OllamaCleanupService.probe()
            viewModel.cleanupProbeStatus = status
            viewModel.isProbingCleanup = false
        }
    }
}

struct SettingsFluidAudioModel: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    var isDownloaded: Bool
    let description: String
    var downloadProgress: Double = 0.0
}

struct SettingsFluidAudioModels {
    static let availableModels = [
        SettingsFluidAudioModel(
            name: "Parakeet v3",
            version: "v3",
            isDownloaded: false,
            description: "Multilingual, 25 languages"
        ),
        SettingsFluidAudioModel(
            name: "Parakeet v2",
            version: "v2",
            isDownloaded: false,
            description: "English-only, higher recall"
        )
    ]
}

enum OnboardingModelType {
    case whisper(url: URL, size: Int)
    case parakeet(version: String)
}

struct OnboardingUnifiedModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let description: String
    let type: OnboardingModelType
    var downloadProgress: Double = 0.0
}

struct OnboardingUnifiedModels {
    static let availableModels = [
        OnboardingUnifiedModel(
            name: "Whisper V3 Large",
            isDownloaded: false,
            description: "High accuracy, best quality",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
                size: 1624
            )
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v3",
            isDownloaded: false,
            description: "Fastest processing and accurate",
            type: .parakeet(version: "v3")
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v2",
            isDownloaded: false,
            description: "Fastest processing and English-only, higher recall",
            type: .parakeet(version: "v2")
        ),
        OnboardingUnifiedModel(
            name: "Whisper Medium",
            isDownloaded: false,
            description: "Balanced speed and accuracy",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
                size: 874
            )
        ),
        OnboardingUnifiedModel(
            name: "Whisper Small",
            isDownloaded: false,
            description: "Very fast processing",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
                size: 574
            )
        )
    ]
}

struct FluidAudioModelDownloadItemView: View {
    @Binding var model: SettingsFluidAudioModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""

    var isSelected: Bool {
        viewModel.fluidAudioModelVersion == model.version
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.callout)
                        .fontWeight(.semibold)

                    if model.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.accentColor)
                            .imageScale(.small)
                    }
                }

                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.7)
                        .padding(.top, 4)
                } else if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }

            Spacer()

            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        viewModel.fluidAudioModelVersion = model.version
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.downloadFluidAudioModel(model)
                        } catch is CancellationError {
                            // Manual cancellation; no alert.
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                viewModel.fluidAudioModelVersion = model.version
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

struct ModelDownloadItemView: View {
    @Binding var model: SettingsDownloadableModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""

    var isSelected: Bool {
        if let selectedURL = viewModel.selectedModelURL {
            let filename = model.url.lastPathComponent
            return selectedURL.lastPathComponent == filename
        }
        return false
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.callout)
                        .fontWeight(.semibold)

                    Text(model.sizeString)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule())

                    if model.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.accentColor)
                            .imageScale(.small)
                    }
                }

                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }

            Spacer()

            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.url.lastPathComponent).path
                        viewModel.selectedModelURL = URL(fileURLWithPath: modelPath)
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.downloadModel(model)
                        } catch is CancellationError {
                            // Manual cancellation; no alert.
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.url.lastPathComponent).path
                viewModel.selectedModelURL = URL(fileURLWithPath: modelPath)
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

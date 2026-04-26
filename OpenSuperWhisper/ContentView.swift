//
//  ContentView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import Combine
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class ContentViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var transcriptionService = TranscriptionService.shared
    @Published var transcriptionQueue = TranscriptionQueue.shared
    @Published var recordingStore = RecordingStore.shared
    @Published var recordings: [Recording] = []
    @Published var isLoadingMore = false
    @Published var canLoadMore = true
    @Published var recordingDuration: TimeInterval = 0
    @Published var microphoneService = MicrophoneService.shared
    @Published var shouldClearSearch = false

    private var currentPage = 0
    private let pageSize = 100
    private var currentSearchQuery = ""
    private var blinkTimer: Timer?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting && self.state != .decoding {
                    self.state = .connecting
                    self.stopBlinking()
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)

        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording && self.state != .decoding {
                    self.state = .recording
                    self.startBlinking()
                    self.startDurationTimerIfNeeded()
                } else if !isRecording && self.state == .recording {
                    self.state = .idle
                    self.stopBlinking()
                    self.stopDurationTimer()
                    self.recordingDuration = 0
                }
            }
            .store(in: &cancellables)
    }

    func loadInitialData() {
        currentSearchQuery = ""
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }

    func loadMore() {
        guard !isLoadingMore && canLoadMore else { return }
        isLoadingMore = true

        let page = currentPage
        let limit = pageSize
        let query = currentSearchQuery
        let offset = page * limit

        Task {
            let newRecordings: [Recording]
            if query.isEmpty {
                newRecordings = try await recordingStore.fetchRecordings(limit: limit, offset: offset)
            } else {
                newRecordings = await recordingStore.searchRecordingsAsync(query: query, limit: limit, offset: offset)
            }

            await MainActor.run {
                defer {
                    self.isLoadingMore = false
                }

                guard self.currentSearchQuery == query else {
                    return
                }

                if page == 0 {
                    self.recordings = newRecordings
                } else {
                    self.recordings.append(contentsOf: newRecordings)
                }

                if newRecordings.count < limit {
                    self.canLoadMore = false
                } else {
                    self.currentPage += 1
                }
            }
        }
    }

    func search(query: String) {
        currentSearchQuery = query
        currentPage = 0
        canLoadMore = true
        recordings = []
        loadMore()
    }

    func handleProgressUpdate(id: UUID, transcription: String?, progress: Float, status: RecordingStatus, isRegeneration: Bool?) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            if let transcription = transcription {
                recordings[index].transcription = transcription
            }
            recordings[index].progress = progress
            recordings[index].status = status
            if let isRegeneration = isRegeneration {
                recordings[index].isRegeneration = isRegeneration
            }
        }
    }

    func deleteRecording(_ recording: Recording) {
        recordingStore.deleteRecording(recording)
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings.remove(at: index)
        }
    }

    func deleteAllRecordings() {
        recordingStore.deleteAllRecordings()
        recordings.removeAll()
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    func startRecording() {
        if microphoneService.isActiveMicrophoneRequiresConnection() {
            state = .connecting
            stopBlinking()
            stopDurationTimer()
            recordingDuration = 0
        } else {
            state = .recording
            startBlinking()
            recordingStartTime = Date()
            recordingDuration = 0
            startDurationTimerIfNeeded()
        }

        Task.detached { [recorder] in
            recorder.startRecording()
        }
    }

    func startDecoding() {
        state = .decoding
        stopBlinking()
        stopDurationTimer()

        IndicatorWindowManager.shared.hide()

        if let tempURL = recorder.stopRecording() {
            Task { [weak self] in
                guard let self = self else { return }

                do {
                    let text = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())

                    let duration = await MainActor.run { self.recordingDuration }

                    let timestamp = Date()
                    let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                    let recordingId = UUID()
                    let finalURL = Recording(
                        id: recordingId,
                        timestamp: timestamp,
                        fileName: fileName,
                        transcription: text,
                        duration: duration,
                        status: .completed,
                        progress: 1.0,
                        sourceFileURL: nil
                    ).url

                    try recorder.moveTemporaryRecording(from: tempURL, to: finalURL)

                    await MainActor.run {
                        let newRecording = Recording(
                            id: recordingId,
                            timestamp: timestamp,
                            fileName: fileName,
                            transcription: text,
                            duration: self.recordingDuration,
                            status: .completed,
                            progress: 1.0,
                            sourceFileURL: nil
                        )
                        self.recordingStore.addRecording(newRecording)

                        if !self.currentSearchQuery.isEmpty {
                            self.shouldClearSearch = true
                            self.currentSearchQuery = ""
                        }
                        self.recordings.insert(newRecording, at: 0)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                }

                await MainActor.run {
                    self.state = .idle
                    self.recordingDuration = 0
                }
            }
        } else {
            state = .idle
            recordingDuration = 0
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
    }

    private func startDurationTimerIfNeeded() {
        guard durationTimer == nil else { return }
        if recordingStartTime == nil {
            recordingStartTime = Date()
            recordingDuration = 0
        }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let startTime = Date()
            Task { @MainActor in
                if let recordingStartTime = self.recordingStartTime {
                    self.recordingDuration = startTime.timeIntervalSince(recordingStartTime)
                }
            }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.isBlinking.toggle()
            }
        }
        RunLoop.main.add(blinkTimer!, forMode: .common)
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @StateObject private var permissionsManager = PermissionsManager()
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSettingsPresented = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showDeleteConfirmation = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var isDropTargeted = false

    private var currentShortcutDescription: String {
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        if modifierKey != .none {
            return modifierKey.shortSymbol
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
            return shortcut.description
        }
        return ""
    }

    private func performSearch(_ query: String) {
        searchTask?.cancel()

        if query.isEmpty {
            debouncedSearchText = ""
            viewModel.search(query: "")
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.debouncedSearchText = query
                viewModel.search(query: query)
            }
        }
    }

    var body: some View {
        ZStack {
            YapWindowBackground(colorScheme: colorScheme)
                .ignoresSafeArea()

            if !permissionsManager.isMicrophonePermissionGranted
                || !permissionsManager.isAccessibilityPermissionGranted {
                PermissionsView(permissionsManager: permissionsManager)
            } else {
                mainLayout
            }
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 560, idealHeight: 720)
        .onAppear {
            viewModel.loadInitialData()
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingProgressDidUpdateNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let id = userInfo["id"] as? UUID,
                  let progress = userInfo["progress"] as? Float,
                  let status = userInfo["status"] as? RecordingStatus else { return }

            let transcription = userInfo["transcription"] as? String
            let isRegeneration = userInfo["isRegeneration"] as? Bool

            viewModel.handleProgressUpdate(
                id: id,
                transcription: transcription,
                progress: progress,
                status: status,
                isRegeneration: isRegeneration
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingStore.recordingsDidUpdateNotification)) { _ in
            viewModel.loadInitialData()
        }
        .overlay {
            let isPermissionsGranted = permissionsManager.isMicrophonePermissionGranted
                && permissionsManager.isAccessibilityPermissionGranted

            if viewModel.transcriptionService.isLoading && isPermissionsGranted {
                ZStack {
                    Color.black.opacity(0.35)
                    GlassCard {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.3)
                            Text("Loading Whisper Model")
                                .foregroundColor(.primary)
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                        }
                        .padding(28)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .fileDropHandler()
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            isSettingsPresented = true
        }
        .onChange(of: viewModel.shouldClearSearch) { _, shouldClear in
            if shouldClear {
                searchText = ""
                debouncedSearchText = ""
                searchTask?.cancel()
                viewModel.shouldClearSearch = false
            }
        }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            HeaderBar(
                microphoneService: viewModel.microphoneService,
                onSettingsTap: { isSettingsPresented.toggle() }
            )
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            searchField
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            ZStack {
                recordingsArea

                if isDropTargeted {
                    DropTargetOverlay()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
            .layoutPriority(1)

            controlsBar
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 10)

            if viewModel.transcriptionQueue.isProcessing {
                QueueProgressBar(
                    queue: viewModel.transcriptionQueue,
                    transcriptionService: viewModel.transcriptionService,
                    recordings: viewModel.recordings
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.transcriptionQueue.isProcessing)
        .onDrop(of: [.audio, .fileURL], isTargeted: $isDropTargeted) { _ in
            return false
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 13, weight: .medium))

            TextField("Search transcriptions", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(.body, design: .rounded))
                .onChange(of: searchText) { _, newValue in
                    performSearch(newValue)
                }

            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                    debouncedSearchText = ""
                    searchTask?.cancel()
                    viewModel.search(query: "")
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var recordingsArea: some View {
        ScrollView(showsIndicators: false) {
            if viewModel.recordings.isEmpty {
                EmptyStateView(
                    isSearching: !debouncedSearchText.isEmpty,
                    shortcutDescription: currentShortcutDescription
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.horizontal, 24)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.recordings) { recording in
                        RecordingRow(
                            recording: recording,
                            searchQuery: debouncedSearchText,
                            onDelete: {
                                viewModel.deleteRecording(recording)
                            },
                            onRegenerate: {
                                Task {
                                    await TranscriptionQueue.shared.requeueRecording(recording)
                                }
                            }
                        )
                        .id(recording.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            if recording.id == viewModel.recordings.last?.id {
                                viewModel.loadMore()
                            }
                        }
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
        }
        .opacity(isDropTargeted ? 0.35 : 1.0)
        .animation(.easeInOut(duration: 0.22), value: viewModel.recordings.count)
        .animation(.easeInOut(duration: 0.18), value: debouncedSearchText.isEmpty)
    }

    private var controlsBar: some View {
        HStack(alignment: .center, spacing: 12) {
            recordPrimaryControl

            Spacer()

            HStack(spacing: 10) {
                MicrophonePickerIconView(microphoneService: viewModel.microphoneService)

                if !viewModel.recordings.isEmpty {
                    GlassIconButton(
                        systemName: "trash",
                        helpText: "Delete all recordings",
                        action: { showDeleteConfirmation = true }
                    )
                    .confirmationDialog(
                        "Delete All Recordings",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete All", role: .destructive) {
                            viewModel.deleteAllRecordings()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Are you sure you want to delete all recordings? This action cannot be undone.")
                    }
                    .interactiveDismissDisabled()
                }

                GlassIconButton(
                    systemName: "gearshape",
                    helpText: "Settings",
                    action: { isSettingsPresented.toggle() }
                )
            }
        }
    }

    private var recordPrimaryControl: some View {
        Button(action: {
            if viewModel.isRecording {
                viewModel.startDecoding()
            } else {
                viewModel.startRecording()
            }
        }) {
            HStack(spacing: 10) {
                if viewModel.state == .decoding || viewModel.state == .connecting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    InlineRecordIndicator(isRecording: viewModel.isRecording)
                }

                Text(recordButtonLabel)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(viewModel.isRecording ? Color.red.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.transcriptionService.isLoading || viewModel.transcriptionService.isTranscribing || viewModel.transcriptionQueue.isProcessing || viewModel.state == .decoding)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isRecording)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.state)
        .help(currentShortcutDescription.isEmpty ? "Start recording" : "Press \(currentShortcutDescription) anywhere")
    }

    private var recordButtonLabel: String {
        switch viewModel.state {
        case .recording:
            return "Stop"
        case .decoding:
            return "Transcribing"
        case .connecting:
            return "Connecting"
        case .busy:
            return "Busy"
        case .idle:
            return "Record"
        }
    }
}

private struct YapWindowBackground: View {
    let colorScheme: ColorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white.opacity(0.04), Color.black.opacity(0.18)]
                    : [Color.white.opacity(0.55), Color(red: 0.93, green: 0.95, blue: 0.99).opacity(0.5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.08),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 30,
                endRadius: 380
            )
        }
    }
}

private struct HeaderBar: View {
    @ObservedObject var microphoneService: MicrophoneService
    let onSettingsTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            YapWordmark()

            Spacer()

            MicrophoneStatusPill(microphoneService: microphoneService)

            GlassIconButton(
                systemName: "gearshape",
                helpText: "Settings",
                action: onSettingsTap
            )
        }
    }
}

private struct YapWordmark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }

            Text("Yap")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white, Color.white.opacity(0.78)]
                            : [Color.primary, Color.primary.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}

private struct MicrophoneStatusPill: View {
    @ObservedObject var microphoneService: MicrophoneService

    private var label: String {
        microphoneService.currentMicrophone?.displayName ?? "No microphone"
    }

    private var hasMic: Bool {
        microphoneService.currentMicrophone != nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(hasMic ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)

            Image(systemName: hasMic ? "mic.fill" : "mic.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            Text(label)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help(label)
    }
}

private struct GlassIconButton: View {
    let systemName: String
    let helpText: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(isHovered ? 0.14 : 0.06), lineWidth: 1)
                )
                .scaleEffect(isHovered ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct EmptyStateView: View {
    let isSearching: Bool
    let shortcutDescription: String

    var body: some View {
        VStack(spacing: 16) {
            if isSearching {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.accentColor.opacity(0.6))

                Text("No matches")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)

                Text("Try different search terms.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .symbolRenderingMode(.hierarchical)

                Text("Hold your dictation hotkey anywhere to start")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)

                if !shortcutDescription.isEmpty {
                    HStack(spacing: 6) {
                        Text("Press")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Text(shortcutDescription)
                            .font(.system(.callout, design: .rounded, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                        Text("to dictate.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }

                Text("Or drop an audio file anywhere on this window.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("Built on OpenSuperWhisper · MIT")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: 360)
    }
}

private struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("Drop to transcribe")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InlineRecordIndicator: View {
    let isRecording: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isRecording ? Color.red : Color.accentColor)
                .frame(width: 12, height: 12)

            if isRecording {
                Circle()
                    .stroke(Color.red.opacity(0.5), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.3 : 1.0)
                    .opacity(pulse ? 0 : 1)
                    .animation(
                        .easeOut(duration: 1.0).repeatForever(autoreverses: false),
                        value: pulse
                    )
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct QueueProgressBar: View {
    @ObservedObject var queue: TranscriptionQueue
    @ObservedObject var transcriptionService: TranscriptionService
    let recordings: [Recording]

    private var currentRecording: Recording? {
        guard let id = queue.currentRecordingId else { return nil }
        return recordings.first(where: { $0.id == id })
    }

    private var currentLabel: String {
        if let current = currentRecording {
            if let sourceFileName = current.sourceFileName {
                return sourceFileName
            }
            if !current.transcription.isEmpty
                && current.transcription != "Starting transcription..."
                && current.transcription != "In queue..." {
                return current.transcription
            }
            return "Transcribing"
        }
        return "Processing queue"
    }

    private var progress: Double {
        if transcriptionService.isTranscribing {
            return Double(transcriptionService.progress)
        }
        if let current = currentRecording {
            return Double(current.progress)
        }
        return 0
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(currentLabel)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("\(Int((progress) * 100))%")
                    .font(.system(.caption, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 3)

                GeometryReader { geo in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.7), Color.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, min(1, progress)) * geo.size.width, height: 3)
                        .animation(.linear(duration: 0.15), value: progress)
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1),
            alignment: .top
        )
    }
}

struct PermissionsView: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Required Permissions")
                .font(.system(.title, design: .rounded, weight: .bold))
                .padding()

            PermissionRow(
                isGranted: permissionsManager.isMicrophonePermissionGranted,
                title: "Microphone Access",
                description: "Required for audio recording",
                action: {
                    permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences()
                }
            )

            PermissionRow(
                isGranted: permissionsManager.isAccessibilityPermissionGranted,
                title: "Accessibility Access",
                description: "Required for global keyboard shortcuts",
                action: { permissionsManager.openSystemPreferences(for: .accessibility) }
            )

            Spacer()
        }
        .padding()
    }
}

struct PermissionRow: View {
    let isGranted: Bool
    let title: String
    let description: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isGranted ? .green : .red)

                Text(title)
                    .font(.system(.headline, design: .rounded))

                Spacer()

                if !isGranted {
                    Button("Grant Access") {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

struct RecordingRow: View {
    let recording: Recording
    let searchQuery: String
    let onDelete: () -> Void
    let onRegenerate: () -> Void
    @StateObject private var audioRecorder = AudioRecorder.shared
    @State private var showTranscription = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var isPlaying: Bool {
        audioRecorder.isPlaying && audioRecorder.currentlyPlayingURL == recording.url
    }

    private var isPending: Bool {
        recording.status == .pending || recording.status == .converting || recording.status == .transcribing
    }

    private var isRegenerating: Bool {
        recording.isRegeneration && isPending
    }

    private var statusText: String {
        switch recording.status {
        case .pending:
            return "In queue"
        case .converting:
            return "Converting"
        case .transcribing:
            return "Transcribing"
        case .completed:
            return ""
        case .failed:
            return "Failed"
        }
    }

    private var displayText: String {
        if recording.transcription.isEmpty || recording.transcription == "Starting transcription..." || recording.transcription == "In queue..." {
            return ""
        }
        return recording.transcription
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: recording.timestamp, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metaHeader
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if isPending && !isRegenerating {
                pendingBlock
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            if recording.status == .failed {
                failureBlock
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else if !displayText.isEmpty {
                ZStack(alignment: .topLeading) {
                    TranscriptionView(
                        transcribedText: displayText,
                        searchQuery: searchQuery,
                        isExpanded: $showTranscription
                    )

                    if isRegenerating {
                        ShimmerOverlay()
                            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            } else if !isPending {
                Text("No speech detected")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isHovered
                        ? Color.accentColor.opacity(0.25)
                        : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.06 : 0.0),
            radius: isHovered ? 8 : 0,
            x: 0,
            y: isHovered ? 2 : 0
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var metaHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(relativeTime)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundColor(.primary)

                    if let sourceFileName = recording.sourceFileName, isPending && !isRegenerating {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(sourceFileName)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                HStack(spacing: 4) {
                    Text(TextUtil.formatDuration(recording.duration))
                    Text("·")
                    Text("^[\(TextUtil.wordCount(recording.transcription)) word](inflect: true)")
                }
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.secondary)
            }

            Spacer()

            actionButtons
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if isRegenerating {
                regenerationStatus
            }

            if !isPending && recording.status != .failed && (isHovered || isPlaying) {
                Button(action: {
                    if isPlaying {
                        audioRecorder.stopPlaying()
                    } else {
                        audioRecorder.playRecording(url: recording.url)
                    }
                }) {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(isPlaying ? .red : .accentColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Stop playback" : "Play recording")
                .transition(.opacity)

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        recording.transcription, forType: .string
                    )
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy transcription")
                .transition(.opacity)
            }

            if (recording.status == .completed || recording.status == .failed) && isHovered {
                Button(action: {
                    onRegenerate()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Regenerate transcription")
                .transition(.opacity)
            }

            if isHovered || isPlaying || (isPending && !isRegenerating) || recording.status == .failed {
                Button(action: {
                    if isPlaying {
                        audioRecorder.stopPlaying()
                    }
                    onDelete()
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        .animation(.easeInOut(duration: 0.18), value: isPlaying)
        .animation(.easeInOut(duration: 0.18), value: isRegenerating)
    }

    private var regenerationStatus: some View {
        HStack(spacing: 6) {
            if recording.status == .pending {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 2)

                    Circle()
                        .trim(from: 0, to: CGFloat(recording.progress))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: recording.progress)
                }
                .frame(width: 14, height: 14)

                Text("\(Int(recording.progress * 100))%")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.1), value: recording.progress)
            }

            Text(statusText)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.secondary)
        }
        .transition(.opacity)
    }

    private var pendingBlock: some View {
        HStack(spacing: 8) {
            if recording.status == .pending {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 2)

                    Circle()
                        .trim(from: 0, to: CGFloat(recording.progress))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: recording.progress)
                }
                .frame(width: 16, height: 16)

                Text("\(Int(recording.progress * 100))%")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.1), value: recording.progress)
            }

            Text(statusText)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var failureBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                Text("Transcription failed")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundColor(.red)
            }

            if !recording.transcription.isEmpty {
                Text(recording.transcription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ShimmerOverlay: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.clear,
                                    Color.white.opacity(0.4),
                                    Color.clear
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(x: -geometry.size.width + (phase * geometry.size.width * 2))
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.2)
                .repeatForever(autoreverses: false)
            ) {
                phase = 1
            }
        }
    }
}

struct TranscriptionView: View {
    let transcribedText: String
    let searchQuery: String
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme

    @State private var highlightedAttributedString: AttributedString?
    @State private var computeTask: Task<Void, Never>?

    private var hasMoreLines: Bool {
        !transcribedText.isEmpty && transcribedText.count > 150
    }

    private var highlightedText: Text {
        guard !searchQuery.isEmpty else {
            return Text(transcribedText)
        }
        if let attributed = highlightedAttributedString {
            return Text(attributed)
        }
        return Text(transcribedText)
    }

    private func computeHighlighting() {
        computeTask?.cancel()

        guard !searchQuery.isEmpty else {
            highlightedAttributedString = nil
            return
        }

        let text = transcribedText
        let query = searchQuery

        computeTask = Task.detached(priority: .userInitiated) {
            var attributedString = AttributedString(text)
            let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

            var searchStartIndex = text.startIndex
            while let range = text.range(of: query, options: searchOptions, range: searchStartIndex..<text.endIndex) {
                guard !Task.isCancelled else { return }
                if let attributedRange = Range(range, in: attributedString) {
                    attributedString[attributedRange].backgroundColor = .yellow
                    attributedString[attributedRange].foregroundColor = .black
                }
                searchStartIndex = range.upperBound
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.highlightedAttributedString = attributedString
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if isExpanded {
                    ScrollView {
                        highlightedText
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded {
                                if hasMoreLines {
                                    isExpanded.toggle()
                                }
                            }
                    )
                } else {
                    if hasMoreLines {
                        Button(action: { isExpanded.toggle() }) {
                            highlightedText
                                .font(.callout)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        highlightedText
                            .font(.callout)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            if hasMoreLines {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Show more")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .foregroundColor(.accentColor)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
        .onAppear {
            computeHighlighting()
        }
        .onChange(of: searchQuery) { _, _ in
            computeHighlighting()
        }
        .onChange(of: transcribedText) { _, _ in
            computeHighlighting()
        }
        .onDisappear {
            computeTask?.cancel()
        }
    }
}

struct MicrophonePickerIconView: View {
    @ObservedObject var microphoneService: MicrophoneService
    @State private var showMenu = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var builtInMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { $0.isBuiltIn }
    }

    private var externalMicrophones: [MicrophoneService.AudioDevice] {
        microphoneService.availableMicrophones.filter { !$0.isBuiltIn }
    }

    var body: some View {
        Button(action: {
            showMenu.toggle()
        }) {
            Image(systemName: microphoneService.availableMicrophones.isEmpty ? "mic.slash" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(isHovered ? 0.14 : 0.06), lineWidth: 1)
                )
                .scaleEffect(isHovered ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .help(microphoneService.currentMicrophone?.displayName ?? "Select microphone")
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if microphoneService.availableMicrophones.isEmpty {
                    Text("No microphones available")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(builtInMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    ForEach(externalMicrophones) { microphone in
                        Button(action: {
                            microphoneService.selectMicrophone(microphone)
                            showMenu = false
                        }) {
                            HStack {
                                Text(microphone.displayName)
                                Spacer()
                                if let current = microphoneService.currentMicrophone,
                                   current.id == microphone.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 220)
            .padding(.vertical, 8)
        }
    }
}

struct MainRecordButton: View {
    let isRecording: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var buttonColor: Color {
        ThemePalette.recordButtonBase(colorScheme)
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        isRecording ? Color.red.opacity(0.85) : buttonColor.opacity(0.85),
                        isRecording ? Color.red : buttonColor.opacity(0.95)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 48, height: 48)
            .shadow(
                color: isRecording ? .red.opacity(0.5) : buttonColor.opacity(0.3),
                radius: 12,
                x: 0,
                y: 0
            )
            .overlay {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                isRecording ? .red.opacity(0.6) : buttonColor.opacity(0.6),
                                isRecording ? .red.opacity(0.3) : buttonColor.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .scaleEffect(isRecording ? 0.9 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
    }
}

enum ThemePalette {
    static func windowBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(NSColor.underPageBackgroundColor)
            : .white
    }

    static func panelSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.gray.opacity(0.1)
            : Color(red: 0.95, green: 0.96, blue: 0.98)
    }

    static func panelBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.gray.opacity(0.2)
            : Color(red: 0.86, green: 0.88, blue: 0.92)
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(NSColor.controlBackgroundColor)
            : Color.white
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(NSColor.separatorColor)
            : Color(red: 0.86, green: 0.88, blue: 0.92)
    }

    static func recordButtonBase(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? .white
            : Color(red: 0.35, green: 0.60, blue: 0.92)
    }

    static func iconAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .accentColor : .primary
    }

    static func linkText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .blue : .primary
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

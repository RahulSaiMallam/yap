import AVFoundation
import Cocoa
import Combine
import SwiftUI
import UserNotifications

enum RecordingState {
    case idle
    case connecting
    case recording
    case decoding
    case busy
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {

    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var isVisible = false

    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue

    init() {
        self.recordingStore = RecordingStore.shared
        self.transcriptionService = TranscriptionService.shared
        self.transcriptionQueue = TranscriptionQueue.shared

        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting {
                    self.state = .connecting
                    self.stopBlinking()
                }
            }
            .store(in: &cancellables)

        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording {
                    self.state = .recording
                    self.startBlinking()
                }
            }
            .store(in: &cancellables)
    }

    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing
    }

    func showBusyMessage() {
        state = .busy

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }

    func startRecording() {
        if isTranscriptionBusy {
            showBusyMessage()
            return
        }

        if MicrophoneService.shared.isActiveMicrophoneRequiresConnection() {
            state = .connecting
            stopBlinking()
        } else {
            state = .recording
            startBlinking()
        }

        Task.detached { [recorder] in
            recorder.startRecording()
        }
    }

    func startDecoding() {
        stopBlinking()

        if isTranscriptionBusy {
            recorder.cancelRecording()
            showBusyMessage()
            return
        }

        state = .decoding
        // Play the end sound right when the user releases the hotkey
        // (= "submit"), not after transcription finishes. WisprFlow-style
        // immediate acknowledgement; transcription runs silently after.
        DictationSoundPlayer.playEnd()

        if let tempURL = recorder.stopRecording() {
            Task { [weak self] in
                guard let self = self else { return }

                do {
                    print("start decoding...")
                    let rawText = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
                    let cleanedText: String
                    if AppPreferences.shared.aiCleanupEnabled {
                        cleanedText = await OllamaCleanupService.clean(rawText)
                    } else {
                        cleanedText = rawText
                    }

                    // Create a new Recording instance — store the raw transcript
                    // so users can audit what the model originally heard before
                    // any LLM rewrite was applied.
                    let timestamp = Date()
                    let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                    let recordingId = UUID()
                    let finalURL = Recording(
                        id: recordingId,
                        timestamp: timestamp,
                        fileName: fileName,
                        transcription: rawText,
                        duration: 0,
                        status: .completed,
                        progress: 1.0,
                        sourceFileURL: nil
                    ).url

                    // Move the temporary recording to final location
                    try recorder.moveTemporaryRecording(from: tempURL, to: finalURL)

                    // Save the recording to store
                    await MainActor.run {
                        self.recordingStore.addRecording(Recording(
                            id: recordingId,
                            timestamp: timestamp,
                            fileName: fileName,
                            transcription: rawText,
                            duration: 0,
                            status: .completed,
                            progress: 1.0,
                            sourceFileURL: nil
                        ))
                    }

                    insertText(cleanedText)
                    print("Transcription result: \(cleanedText)")
                } catch {
                    print("Error transcribing audio: \(error)")
                    try? FileManager.default.removeItem(at: tempURL)
                    await MainActor.run { DictationSoundPlayer.stopBufferLoop() }
                }

                await MainActor.run {
                    self.delegate?.didFinishDecoding()
                }
            }
        } else {

            print("!!! Not found record url !!!")
            DictationSoundPlayer.stopBufferLoop()

            Task {
                await MainActor.run {
                    self.delegate?.didFinishDecoding()
                }
            }
        }
    }

    /// Default delay between paste and synthetic Return when
    /// auto-submitting into a chat app, used when the user pref is not
    /// set or out of bounds.
    private static let autoSubmitDelayFallback: TimeInterval = 0.6
    private static let autoSubmitDelayBounds: ClosedRange<TimeInterval> = 0.2...3.0

    func insertText(_ text: String) {
        let finalText = Self.applyPostProcessing(text)
        DiagLog.write("insertText textField=\(ShortcutManager.hotkeyPressedInTextField) chatApp=\(ShortcutManager.hotkeyPressedInChatApp) autoSubmit=\(AppPreferences.shared.autoSubmitInChatApps)")
        if ShortcutManager.hotkeyPressedInTextField {
            ClipboardUtil.insertText(finalText)
            if ShortcutManager.hotkeyPressedInChatApp,
               AppPreferences.shared.autoSubmitInChatApps {
                Self.scheduleAutoSubmit()
            }
        } else {
            // Hotkey was pressed without an editable text field focused
            // (e.g. on Finder, the desktop, or a menu). Skip the Cmd+V
            // simulation — it would either do nothing or trigger an
            // unrelated paste action — and surface a notification so the
            // user knows the dictation is recoverable from the clipboard.
            ClipboardUtil.copyToClipboard(finalText)
            Self.showCopiedNotification(preview: finalText)
        }
    }

    /// Posts a synthetic Return after `autoSubmitDelay`, but only if the
    /// focused chat app hasn't changed in the meantime. The delay window
    /// gives the user a chance to switch focus and abort an unintended
    /// auto-send.
    @MainActor
    private static func scheduleAutoSubmit() {
        let originalBundleID = FocusUtils.currentFocusedBundleID()
        let configured = AppPreferences.shared.autoSubmitDelaySeconds
        let delay = autoSubmitDelayBounds.contains(configured) ? configured : autoSubmitDelayFallback
        DiagLog.write("autoSubmit scheduling for \(originalBundleID ?? "nil") in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let nowBundleID = FocusUtils.currentFocusedBundleID()
            DiagLog.write("autoSubmit firing? was=\(originalBundleID ?? "nil") now=\(nowBundleID ?? "nil")")
            guard nowBundleID == originalBundleID else { return }
            ClipboardUtil.simulateReturn()
        }
    }

    @MainActor
    private static func showCopiedNotification(preview: String) {
        let snippet = preview.count > 80
            ? String(preview.prefix(80)) + "…"
            : preview
        let content = UNMutableNotificationContent()
        content.title = "Copied — press ⌘V to paste"
        content.body = snippet

        let request = UNNotificationRequest(
            identifier: "osw.copied.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request, withCompletionHandler: nil)
        }
    }

    static func applyPostProcessing(_ text: String) -> String {
        guard AppPreferences.shared.addSpaceAfterSentence,
              let lastChar = text.last,
              lastChar.isPunctuation else {
            return text
        }
        return text + " "
    }

    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            // Update UI on the main thread
            Task { @MainActor in
                guard let self = self else { return }
                self.isBlinking.toggle()
            }
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    func cleanup() {
        stopBlinking()
        hideTimer?.invalidate()
        hideTimer = nil
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        recorder.cancelRecording()
    }

    @MainActor
    func hideWithAnimation() async {
        await withCheckedContinuation { continuation in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.isVisible = false
            } completion: {
                continuation.resume()
            }
        }
    }
}

private let orbDiameter: CGFloat = 44

/// Polished dark sphere body — radial gradient gives top-left
/// illumination, a soft inner specular layer reads as a real specular
/// highlight (the pearl/onyx effect), and a hairline border stops the
/// orb from disappearing into very dark backgrounds.
private struct OrbBackground: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(white: 0.18), location: 0.0),
                        .init(color: Color(white: 0.05), location: 0.75),
                        .init(color: .black, location: 1.0)
                    ]),
                    center: UnitPoint(x: 0.32, y: 0.28),
                    startRadius: 1,
                    endRadius: orbDiameter * 0.75
                )
            )
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.28), Color.white.opacity(0)],
                            center: UnitPoint(x: 0.34, y: 0.26),
                            startRadius: 0,
                            endRadius: orbDiameter * 0.28
                        )
                    )
                    .blendMode(.screen)
            )
            .overlay(
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.6)
            )
    }
}

/// Soft inner radial glow at the orb's center that breathes — both the
/// glow's opacity and its radius pulse on the same period, so the orb
/// reads as alive without resorting to motion that suggests "loading."
private struct OrbBreathing: View {
    private let breathPeriodSeconds: Double = 2.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * (2 * .pi / breathPeriodSeconds))
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.42 + 0.30 * pulse),
                            Color.white.opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 9 + 4 * CGFloat(pulse)
                    )
                )
                .frame(width: 28, height: 28)
        }
    }
}

/// Bright crescent that orbits the orb's inner wall. A faint ghost ring
/// sits behind it so the orbit path is visible — the crescent then
/// reads as a comet sliding through, not a disconnected stroke.
private struct OrbCrescent: View {
    private let cycleSeconds: Double = 1.8
    private let trim: Double = 0.22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: cycleSeconds)) / cycleSeconds
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 1.2)

                Circle()
                    .trim(from: 0.0, to: trim)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.95)
                            ]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * trim)
                        ),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(phase * 360 - 90))
            }
            .frame(width: 30, height: 30)
        }
    }
}

/// Round dark orb that floats at the bottom of the screen — pearl/onyx
/// finish from the radial gradient and inner highlight so it reads as a
/// physical object, not a 2D circle. Outer padding gives the drop
/// shadow room to render before NSHostingView clips to bounds.
struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel

    var body: some View {
        ZStack {
            OrbBackground()
            content
                .id(viewModel.state)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
        .frame(width: orbDiameter, height: orbDiameter)
        .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 5)
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
        .padding(16)
        .scaleEffect(viewModel.isVisible ? 1 : 0.84)
        .offset(y: viewModel.isVisible ? 0 : 8)
        .opacity(viewModel.isVisible ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: viewModel.isVisible)
        .animation(.easeInOut(duration: 0.35), value: viewModel.state)
        .onAppear {
            viewModel.isVisible = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
                .tint(.white)

        case .recording:
            OrbBreathing()

        case .decoding:
            OrbCrescent()

        case .busy:
            Image(systemName: "hourglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)

        case .idle:
            EmptyView()
        }
    }
}

/// Plays the start / end WAVs shipped in the bundle, plus a seamlessly
/// looping "buffer" sound that runs while transcription is in flight.
/// All playback is best-effort: any failure (file missing, audio device
/// unavailable, pref disabled) is silent — the dictation pipeline never
/// depends on sound playback succeeding. AVAudioPlayer is used for the
/// loop because NSSound's loops property is unreliable across macOS
/// versions and tends to introduce a click at the loop seam.
enum DictationSoundPlayer {
    @MainActor private static var startSound: NSSound?
    @MainActor private static var endSound: NSSound?
    @MainActor private static var bufferPlayer: AVAudioPlayer?

    @MainActor static func playStart() {
        guard AppPreferences.shared.playSoundOnRecordStart else { return }
        if startSound == nil {
            startSound = loadSound(named: "sound_start", ext: "wav")
        }
        startSound?.stop()
        startSound?.currentTime = 0
        startSound?.play()
    }

    @MainActor static func playEnd() {
        guard AppPreferences.shared.playSoundOnRecordStart else { return }
        if endSound == nil {
            endSound = loadSound(named: "sound_end", ext: "wav")
        }
        endSound?.stop()
        endSound?.currentTime = 0
        endSound?.play()
    }

    @MainActor static func startBufferLoop() {
        guard AppPreferences.shared.playSoundOnRecordStart else { return }
        if bufferPlayer == nil {
            guard let url = Bundle.main.url(forResource: "sound_buffer", withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { return }
            player.numberOfLoops = -1
            bufferPlayer = player
        }
        bufferPlayer?.currentTime = 0
        bufferPlayer?.volume = 0
        bufferPlayer?.play()
        bufferPlayer?.setVolume(0.45, fadeDuration: 0.25)
    }

    @MainActor static func stopBufferLoop() {
        guard let player = bufferPlayer, player.isPlaying else { return }
        // Fade out over 280ms so the buffer doesn't cut abruptly before
        // the end sound. The end sound starts playing simultaneously,
        // creating a smooth handoff.
        player.setVolume(0, fadeDuration: 0.28)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            player.stop()
        }
    }

    @MainActor private static func loadSound(named name: String, ext: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let sound = NSSound(contentsOf: url, byReference: false) else {
            return nil
        }
        sound.volume = 0.55
        return sound
    }
}

/// A standalone "Copied — press ⌘V to paste" toast that mirrors the
/// glass pill styling. Not currently wired to the live indicator
/// pipeline (the `UNUserNotificationCenter` fallback in
/// `IndicatorViewModel.showCopiedNotification` remains the source of
/// truth) but available for future use without needing to redesign
/// the surface.
struct CopiedToastView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let accent = Color(red: 0.45, green: 0.82, blue: 0.62)

    var body: some View {
        let pill = Capsule(style: .continuous)

        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
            Text("Copied — press ⌘V to paste")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .fixedSize(horizontal: true, vertical: false)
        .background(.ultraThinMaterial, in: pill)
        .overlay(
            pill.fill(
                colorScheme == .dark
                    ? Color(red: 0.20, green: 0.30, blue: 0.26).opacity(0.18)
                    : Color.clear
            )
        )
        .overlay(
            pill.stroke(
                LinearGradient(
                    colors: [accent.opacity(0.4), accent.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        )
        .clipShape(pill)
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)
    }
}

struct IndicatorViewPreview: View {
    @StateObject private var idleVM: IndicatorViewModel = {
        let vm = IndicatorViewModel()
        vm.state = .idle
        vm.isVisible = true
        return vm
    }()

    @StateObject private var connectingVM: IndicatorViewModel = {
        let vm = IndicatorViewModel()
        vm.state = .connecting
        vm.isVisible = true
        return vm
    }()

    @StateObject private var recordingVM: IndicatorViewModel = {
        let vm = IndicatorViewModel()
        vm.state = .recording
        vm.isVisible = true
        return vm
    }()

    @StateObject private var decodingVM: IndicatorViewModel = {
        let vm = IndicatorViewModel()
        vm.state = .decoding
        vm.isVisible = true
        return vm
    }()

    @StateObject private var busyVM: IndicatorViewModel = {
        let vm = IndicatorViewModel()
        vm.state = .busy
        vm.isVisible = true
        return vm
    }()

    var body: some View {
        VStack(spacing: 18) {
            IndicatorWindow(viewModel: connectingVM)
            IndicatorWindow(viewModel: recordingVM)
            IndicatorWindow(viewModel: decodingVM)
            IndicatorWindow(viewModel: busyVM)
            CopiedToastView()
        }
        .padding(40)
    }
}

struct IndicatorWindowPreview: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.08, blue: 0.18),
                    Color(red: 0.18, green: 0.12, blue: 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            IndicatorViewPreview()
        }
        .frame(width: 360, height: 360)
    }
}

#Preview("Dark") {
    IndicatorWindowPreview()
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    IndicatorViewPreview()
        .background(Color(.windowBackgroundColor))
        .preferredColorScheme(.light)
}

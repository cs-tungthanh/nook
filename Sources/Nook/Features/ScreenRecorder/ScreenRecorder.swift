import AppKit
import Combine
import ScreenCaptureKit
import AVFoundation

enum RecordingSource: String, CaseIterable, Identifiable {
    case screen
    case allScreens
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Screen"
        case .allScreens: return "All screens"
        case .area: return "Area"
        }
    }
}

struct DisplayOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

/// An area the user dragged out, in points relative to the top-left of its display.
struct AreaSelection {
    let displayID: CGDirectDisplayID
    let rect: CGRect
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Records one screen, every screen side by side, or a dragged-out area, with
/// optional system audio and microphone. Stop pauses the recording: the user
/// can resume into the same movie, or save it to a name and folder they pick.
/// Needs macOS 15 for microphone capture; on older systems `start()` reports an error.
final class ScreenRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case selectingArea
        case starting
        case recording
        case pausing
        case paused
        case saving
    }

    @Published private(set) var state: State = .idle {
        didSet { onChange?() }
    }

    @Published private(set) var errorMessage: String?
    /// True when the last error can be fixed in System Settings › Privacy & Security
    @Published private(set) var needsPrivacySettings = false
    /// Connected screens, left to right
    @Published private(set) var displays: [DisplayOption] = []

    @Published var source: RecordingSource {
        didSet { defaults.set(source.rawValue, forKey: Constants.Recording.Keys.source) }
    }

    @Published var selectedDisplayID: CGDirectDisplayID {
        didSet { defaults.set(Int(selectedDisplayID), forKey: Constants.Recording.Keys.display) }
    }

    @Published var capturesSystemAudio: Bool {
        didSet { defaults.set(capturesSystemAudio, forKey: Constants.Recording.Keys.systemAudio) }
    }

    @Published var capturesMicrophone: Bool {
        didSet { defaults.set(capturesMicrophone, forKey: Constants.Recording.Keys.microphone) }
    }

    /// Called on every state change so the menu bar can refresh.
    var onChange: (() -> Void)?

    private struct Capture {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
    }

    private let defaults = UserDefaults.standard
    private let sampleQueue = DispatchQueue(label: "com.nook.screen-recorder.samples")
    /// What to capture, kept so Resume can start identical streams
    private var captures: [Capture] = []
    private var streams: [SCStream] = []
    private var sinks: [StreamSink] = []
    private var writer: RecordingWriter?
    private var areaSelector: AreaSelector?
    /// Time recorded in earlier segments, before the last Resume
    private var recordedDuration: TimeInterval = 0
    private var segmentStartedAt: Date?
    private var saveHandlers: [() -> Void] = []

    override init() {
        defaults.register(defaults: [
            Constants.Recording.Keys.systemAudio: true,
            Constants.Recording.Keys.microphone: false,
            Constants.Recording.Keys.source: RecordingSource.screen.rawValue
        ])
        capturesSystemAudio = defaults.bool(forKey: Constants.Recording.Keys.systemAudio)
        capturesMicrophone = defaults.bool(forKey: Constants.Recording.Keys.microphone)
        source = RecordingSource(rawValue: defaults.string(forKey: Constants.Recording.Keys.source) ?? "") ?? .screen
        selectedDisplayID = CGDirectDisplayID(defaults.integer(forKey: Constants.Recording.Keys.display))
        super.init()
        refreshDisplays()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    var isRecording: Bool { state == .recording || state == .pausing }

    var isPaused: Bool { state == .paused }

    /// A recording is in progress or stopped and not yet saved
    var hasUnsavedRecording: Bool { isRecording || isPaused }

    /// Total recorded time, excluding pauses
    var elapsed: TimeInterval {
        recordedDuration + (segmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    var selectedDisplayName: String {
        displays.first { $0.id == selectedDisplayID }?.name ?? "Main screen"
    }

    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    // MARK: Actions

    func start() {
        guard state == .idle else { return }
        guard Self.isSupported else {
            errorMessage = "Screen recording needs macOS 15 or later."
            return
        }
        errorMessage = nil
        needsPrivacySettings = false

        guard source == .area else {
            begin(area: nil)
            return
        }
        state = .selectingArea
        let selector = AreaSelector { [weak self] selection in
            guard let self = self else { return }
            self.areaSelector = nil
            if let selection = selection {
                self.begin(area: selection)
            } else {
                self.state = .idle
            }
        }
        areaSelector = selector
        selector.show()
    }

    /// Stops capturing but keeps the movie open so the user can resume or save it.
    func pause(completion: (() -> Void)? = nil) {
        guard state == .recording else {
            completion?()
            return
        }
        state = .pausing
        Task { @MainActor in
            await self.stopStreams()
            // A failure while stopping already reset the recorder
            if self.state == .pausing { self.state = .paused }
            completion?()
        }
    }

    func resume() {
        guard state == .paused else { return }
        errorMessage = nil
        needsPrivacySettings = false
        state = .starting
        Task { @MainActor in
            do {
                try await self.startStreams()
                self.state = .recording
            } catch {
                NSLog("Nook: resuming screen recording failed: \(error.localizedDescription)")
                self.errorMessage = "Couldn't resume: \(error.localizedDescription)"
                self.state = .paused
            }
        }
    }

    /// Finishes the movie and asks where to save it. Stops first if still recording;
    /// `completion` runs once the file is saved or deleted (or right away if there's nothing to save).
    func save(completion: (() -> Void)? = nil) {
        if state == .recording {
            pause { [weak self] in
                guard let self = self else { completion?(); return }
                self.save(completion: completion)
            }
            return
        }
        guard state == .paused, let writer = writer else {
            completion?()
            return
        }
        if let completion = completion { saveHandlers.append(completion) }
        state = .saving
        writer.finish { [weak self] url in
            guard let self = self else { return }
            self.reset()
            if let url = url {
                self.promptToSave(url)
            } else {
                self.errorMessage = "Nothing was recorded"
            }
            self.runSaveHandlers()
        }
    }

    /// Deletes a stopped recording after the user confirms.
    func discard() {
        guard state == .paused, let writer = writer else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard confirmDiscard(keepTitle: "Keep") else { return }
        writer.cancel()
        reset()
    }

    // MARK: Displays

    @objc private func screensChanged() {
        refreshDisplays()
    }

    private func refreshDisplays() {
        displays = NSScreen.screens
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { screen in screen.displayID.map { DisplayOption(id: $0, name: screen.localizedName) } }
        if !displays.contains(where: { $0.id == selectedDisplayID }),
           let fallback = NSScreen.main?.displayID ?? displays.first?.id {
            selectedDisplayID = fallback
        }
    }

    // MARK: Recording

    private func begin(area: AreaSelection?) {
        guard #available(macOS 15.0, *) else { return }
        state = .starting
        Task { @MainActor in
            do {
                try await self.beginRecording(area: area)
            } catch {
                self.fail(error)
            }
        }
    }

    @available(macOS 15.0, *)
    @MainActor
    private func beginRecording(area: AreaSelection?) async throws {
        if capturesMicrophone {
            try await requestMicrophoneAccess()
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            NSLog("Nook: listing shareable content failed: \(error.localizedDescription)")
            throw RecorderError.screenAccessDenied
        }

        let chosen = chooseDisplays(from: content.displays, area: area)
        guard !chosen.isEmpty else { throw RecorderError.noDisplay }

        // Leave Nook's own island and overlays out of the video
        let nook = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filters = chosen.map { SCContentFilter(display: $0, excludingApplications: nook, exceptingWindows: []) }
        let pixelSizes = filters.map { filter -> CGSize in
            let points = area?.rect.size ?? filter.contentRect.size
            let scale = CGFloat(filter.pointPixelScale)
            return CGSize(width: points.width * scale, height: points.height * scale)
        }
        let layout = CanvasLayout(sourceSizes: pixelSizes)

        captures = zip(filters, layout.tiles).enumerated().map { index, pair in
            let (filter, tile) = pair
            let config = SCStreamConfiguration()
            config.width = Int(tile.width)
            config.height = Int(tile.height)
            if let area = area {
                config.sourceRect = area.rect
            }
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: Constants.Recording.framesPerSecond)
            config.queueDepth = Constants.Recording.queueDepth
            config.showsCursor = true
            // Audio comes from the first stream only, so it isn't recorded twice
            let recordsAudio = index == 0
            config.capturesAudio = recordsAudio && capturesSystemAudio
            config.captureMicrophone = recordsAudio && capturesMicrophone
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Constants.Recording.audioSampleRate
            config.channelCount = Constants.Recording.audioChannelCount
            return Capture(filter: filter, configuration: config)
        }

        let writer = try RecordingWriter(
            url: Self.makeOutputURL(),
            layout: layout,
            queue: sampleQueue,
            systemAudio: capturesSystemAudio,
            microphone: capturesMicrophone
        )
        writer.onFailure = { [weak self, weak writer] error in
            guard let self = self, self.writer === writer else { return }
            self.fail(error)
        }
        self.writer = writer
        recordedDuration = 0

        try await startStreams()
        state = .recording
    }

    /// The displays to record, in the order they appear in the movie (left to right).
    @available(macOS 15.0, *)
    private func chooseDisplays(from displays: [SCDisplay], area: AreaSelection?) -> [SCDisplay] {
        if let area = area {
            return displays.filter { $0.displayID == area.displayID }
        }
        switch source {
        case .allScreens:
            return displays.sorted { $0.frame.minX < $1.frame.minX }
        case .screen, .area:
            let mainID = NSScreen.main?.displayID
            let display = displays.first { $0.displayID == selectedDisplayID }
                ?? displays.first { $0.displayID == mainID }
                ?? displays.first
            return display.map { [$0] } ?? []
        }
    }

    @MainActor
    private func startStreams() async throws {
        guard #available(macOS 15.0, *), let writer = writer else { return }
        writer.setAccepting(true)
        do {
            for (index, capture) in captures.enumerated() {
                let stream = SCStream(filter: capture.filter, configuration: capture.configuration, delegate: self)
                let sink = StreamSink(index: index, writer: writer)
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sampleQueue)
                if capture.configuration.capturesAudio {
                    try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sampleQueue)
                }
                if capture.configuration.captureMicrophone {
                    try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sampleQueue)
                }
                streams.append(stream)
                sinks.append(sink)
                try await stream.startCapture()
            }
        } catch {
            await stopStreams()
            throw error
        }
        segmentStartedAt = Date()
    }

    @MainActor
    private func stopStreams() async {
        writer?.setAccepting(false)
        if let start = segmentStartedAt {
            recordedDuration += Date().timeIntervalSince(start)
        }
        segmentStartedAt = nil
        let current = streams
        streams = []
        sinks = []
        for stream in current {
            try? await stream.stopCapture()
        }
    }

    private func requestMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw RecorderError.microphoneAccessDenied
        default:
            throw RecorderError.microphoneAccessDenied
        }
    }

    /// Records into a temporary file; the user picks the final name and folder on save.
    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Nook Recording \(formatter.string(from: Date())).mov")
    }

    private func reset() {
        captures = []
        streams = []
        sinks = []
        writer = nil
        recordedDuration = 0
        segmentStartedAt = nil
        state = .idle
    }

    /// Shows a save panel (Desktop by default) until the recording is saved or
    /// the user confirms they want to delete it.
    private func promptToSave(_ recording: URL) {
        NSApp.activate(ignoringOtherApps: true)
        while true {
            let panel = NSSavePanel()
            panel.title = "Save Recording"
            panel.prompt = "Save"
            panel.nameFieldLabel = "Name:"
            panel.nameFieldStringValue = recording.lastPathComponent
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            panel.allowedContentTypes = [.quickTimeMovie]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false

            if panel.runModal() == .OK, let destination = panel.url {
                do {
                    try Self.move(recording, to: destination)
                    Notifier.post(title: "Recording saved", body: destination.lastPathComponent)
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    return
                } catch {
                    NSAlert(error: error).runModal()
                    continue
                }
            }

            if confirmDiscard(keepTitle: "Back to Save") {
                try? FileManager.default.removeItem(at: recording)
                return
            }
        }
    }

    private static func move(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        // The save panel has already asked the user before replacing a file
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    private func confirmDiscard(keepTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "It hasn't been saved yet. If you delete it, it can't be recovered."
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: keepTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func fail(_ error: Error) {
        NSLog("Nook: screen recording failed: \(error.localizedDescription)")
        let recorderError = error as? RecorderError
        errorMessage = recorderError?.message ?? error.localizedDescription
        needsPrivacySettings = recorderError?.needsPrivacySettings ?? false
        let current = streams
        writer?.cancel()
        reset()
        for stream in current {
            Task { try? await stream.stopCapture() }
        }
        runSaveHandlers()
    }

    private func runSaveHandlers() {
        let handlers = saveHandlers
        saveHandlers.removeAll()
        handlers.forEach { $0() }
    }

    enum RecorderError: Error {
        case screenAccessDenied
        case microphoneAccessDenied
        case noDisplay

        var message: String {
            switch self {
            case .screenAccessDenied: return "Allow Nook under Screen & System Audio Recording"
            case .microphoneAccessDenied: return "Allow Nook under Microphone in Privacy settings"
            case .noDisplay: return "That screen isn't connected anymore"
            }
        }

        var needsPrivacySettings: Bool { self != .noDisplay }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Also fires when the user stops sharing from the system's menu bar
        // indicator; keep what was recorded so it can be resumed or saved
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.streams.contains(where: { $0 === stream }) else { return }
            NSLog("Nook: screen capture stopped: \(error.localizedDescription)")
            self.pause()
        }
    }
}

/// Forwards one stream's samples to the writer, tagged with the stream's tile.
private final class StreamSink: NSObject, SCStreamOutput {
    let index: Int
    let writer: RecordingWriter

    init(index: Int, writer: RecordingWriter) {
        self.index = index
        self.writer = writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        writer.append(sampleBuffer, of: type, from: index)
    }
}

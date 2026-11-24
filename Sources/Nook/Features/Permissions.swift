import AppKit
import Combine
import UserNotifications
import AVFoundation
import CoreBluetooth

enum PermissionStatus: Equatable {
    case granted
    case denied
    /// macOS hasn't asked yet; asking shows the system prompt
    case notAsked
    /// Can't be read without side effects (System Events isn't running)
    case unknown

    var label: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .notAsked: return "Not asked yet"
        case .unknown: return "Unknown"
        }
    }
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case screenRecording, microphone, bluetooth, notifications, automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return "Screen & System Audio Recording"
        case .microphone: return "Microphone"
        case .bluetooth: return "Bluetooth"
        case .notifications: return "Notifications"
        case .automation: return "Automation › System Events"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: return "Record your screen and Mac sound"
        case .microphone: return "Include your voice in recordings"
        case .bluetooth: return "List and connect your devices"
        case .notifications: return "Break, shutdown and update notices"
        case .automation: return "Shut down at the scheduled time"
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: return "record.circle"
        case .microphone: return "mic"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .notifications: return "bell"
        case .automation: return "power"
        }
    }

    var settingsURL: URL? {
        switch self {
        case .screenRecording: return URL(string: Constants.Recording.privacySettingsURL)
        case .microphone: return URL(string: Constants.Permissions.microphoneSettingsURL)
        case .bluetooth: return URL(string: Constants.Bluetooth.privacySettingsURL)
        case .automation: return URL(string: Constants.Permissions.automationSettingsURL)
        case .notifications:
            let id = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
            return URL(string: Constants.Permissions.notificationsSettingsURL + id)
        }
    }
}

/// Reads the status of every permission Nook uses, without triggering any
/// prompt, and asks for one on request. Only polls while the page is shown.
final class Permissions: ObservableObject {
    @Published private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    private var timer: Timer?
    /// Created only to ask for Bluetooth; creating it is what shows the prompt
    private var bluetoothCentral: CBCentralManager?
    private let automationQueue = DispatchQueue(label: "com.nook.permissions.automation")

    var isIslandShown = false { didSet { updateTimer() } }
    var isPageShown = false { didSet { updateTimer() } }

    private func updateTimer() {
        let shouldRun = isIslandShown && isPageShown
        guard shouldRun != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard shouldRun else { return }
        refresh()
        let timer = Timer(timeInterval: Constants.Permissions.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func status(of kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .unknown
    }

    func refresh() {
        // Preflight can't tell "denied" from "never asked"; both read as not allowed
        set(.screenRecording, CGPreflightScreenCaptureAccess() ? .granted : .denied)
        set(.microphone, Self.status(AVCaptureDevice.authorizationStatus(for: .audio)))
        set(.bluetooth, Self.status(CBManager.authorization))

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status: PermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional: status = .granted
            case .denied: status = .denied
            case .notDetermined: status = .notAsked
            @unknown default: status = .unknown
            }
            DispatchQueue.main.async { self?.set(.notifications, status) }
        }

        checkAutomation { _ in }
    }

    /// Reads whether Nook may control System Events, without prompting.
    /// Calls back on the main thread.
    func checkAutomation(_ completion: @escaping (PermissionStatus) -> Void) {
        // AEDeterminePermissionToAutomateTarget can block, so it stays off the main thread
        automationQueue.async { [weak self] in
            let status = Self.automationStatus(askingIfNeeded: false)
            DispatchQueue.main.async {
                self?.set(.automation, status)
                completion(status)
            }
        }
    }

    /// Like `checkAutomation`, but launches System Events first when it isn't
    /// running, so the answer is `.unknown` only if it can't be launched.
    /// Never prompts. Calls back on the main thread.
    func checkAutomationLaunchingIfNeeded(_ completion: @escaping (PermissionStatus) -> Void) {
        checkAutomation { [weak self] status in
            guard status == .unknown, let self = self else {
                completion(status)
                return
            }
            self.launchSystemEvents { self.checkAutomation(completion) }
        }
    }

    /// Asks to control System Events, showing the macOS prompt if it hasn't
    /// been answered yet. Calls back on the main thread with the result.
    func askAutomation(_ completion: @escaping (PermissionStatus) -> Void) {
        launchSystemEvents { [weak self] in
            self?.automationQueue.async {
                let status = Self.automationStatus(askingIfNeeded: true)
                DispatchQueue.main.async {
                    self?.set(.automation, status)
                    completion(status)
                }
            }
        }
    }

    /// The target must be running for its permission to be read or asked for;
    /// System Events is a faceless helper, so launching it shows nothing.
    /// `then` runs once it's up (or launching failed), on any thread.
    private func launchSystemEvents(_ then: @escaping () -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Constants.Permissions.systemEventsBundleID) else {
            then()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in then() }
    }

    /// Whether `request(kind)` only re-reads the status in place, showing no
    /// prompt or System Settings, so the island can stay open to show it
    func isCheck(_ kind: PermissionKind) -> Bool {
        kind == .automation && status(of: kind) == .unknown
    }

    /// Shows the system prompt when macOS hasn't asked yet, otherwise opens
    /// the matching pane in System Settings (macOS asks only once). An
    /// Automation status that can't be read (see `isCheck`) is read again instead.
    func request(_ kind: PermissionKind) {
        if isCheck(kind) {
            // Starts System Events and reads again; "Not asked yet" then offers Allow
            checkAutomationLaunchingIfNeeded { _ in }
            return
        }
        if kind == .screenRecording {
            // macOS lists an app under Screen Recording only once it has asked,
            // and preflight can't tell "never asked" from "denied". Asking adds
            // Nook to the list (with a prompt the first time, otherwise nothing),
            // so Settings always has a switch to turn on.
            if status(of: kind) != .granted { CGRequestScreenCaptureAccess() }
            openSettings(for: kind)
            return
        }
        guard status(of: kind) == .notAsked else {
            openSettings(for: kind)
            return
        }
        switch kind {
        case .screenRecording:
            break // handled above
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        case .bluetooth:
            bluetoothCentral = CBCentralManager(delegate: nil, queue: .main)
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        case .automation:
            askAutomation { _ in }
        }
    }

    func openSettings(for kind: PermissionKind) {
        if let url = kind.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func set(_ kind: PermissionKind, _ status: PermissionStatus) {
        if statuses[kind] != status { statuses[kind] = status }
    }

    private static func status(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .unknown
        }
    }

    private static func status(_ authorization: CBManagerAuthorization) -> PermissionStatus {
        switch authorization {
        case .allowedAlways: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .unknown
        }
    }

    private static func automationStatus(askingIfNeeded: Bool) -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: Constants.Permissions.systemEventsBundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let result = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, askingIfNeeded)
        switch result {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown // procNotFound: System Events isn't running
        }
    }
}

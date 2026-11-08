import AVFoundation
import MediaPlayer
import Network
import UIKit

/// iOS implementation of the gateway's `execute` actions.
///
/// Action names match the Android agent so the PC side needs no changes. Actions that
/// iOS does not allow third-party apps to perform return `UNSUPPORTED_ON_IOS` so the
/// Brahma AI can tell the user instead of hanging.
@MainActor
final class DeviceCommandHandler {
    static let agentVersion = "1.0.0"

    private let pathMonitor = NWPathMonitor()
    private var onWifi = true

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor in self?.onWifi = wifi }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.brahma.connect.path"))
    }

    func handle(_ action: String, _ parameters: [String: Any]) -> CommandResult {
        switch action.lowercased() {
        case "get_device_info": return deviceInfo()
        case "get_battery": return battery()
        case "flashlight_on": return flashlight(true)
        case "flashlight_off": return flashlight(false)
        case "launch_app": return launchApp(parameters)
        case "open_url": return openUrl(parameters)
        case "volume_get": return volumeGet()
        case "volume_set": return volumeSet(parameters)
        case "file_list": return fileList(parameters)
        case "file_read": return fileRead(parameters)
        case "file_write": return fileWrite(parameters)
        case "file_delete": return fileDelete(parameters)
        case "unlock_phone", "ui_dump", "ui_tap", "ui_swipe", "ui_type":
            return .fail("UNSUPPORTED_ON_IOS", "'\(action)' requires system-level automation that iOS does not permit for third-party apps.")
        default:
            return .fail("UNKNOWN_COMMAND", "Unsupported command: \(action)")
        }
    }

    // MARK: - Device state

    var wifiConnected: Bool { onWifi }

    func batterySnapshot() -> (percentage: Int, charging: Bool) {
        let level = UIDevice.current.batteryLevel
        let percentage = level < 0 ? -1 : Int((level * 100).rounded())
        let state = UIDevice.current.batteryState
        return (percentage, state == .charging || state == .full)
    }

    private func deviceInfo() -> CommandResult {
        let battery = batterySnapshot()
        return CommandResult(success: true, data: [
            "device_id": NSNull(),
            "device_name": UIDevice.current.name,
            "platform": "ios",
            "os_version": UIDevice.current.systemVersion,
            "agent_version": Self.agentVersion,
            "model": Self.modelIdentifier(),
            "battery": battery.percentage,
            "charging": battery.charging,
            "wifi_state": wifiConnected ? "connected" : "disconnected",
            "capabilities": BrahmaConnectCapabilities.initial,
        ])
    }

    private func battery() -> CommandResult {
        let battery = batterySnapshot()
        return CommandResult(success: true, data: ["percentage": battery.percentage, "charging": battery.charging])
    }

    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    // MARK: - Flashlight

    private func flashlight(_ enabled: Bool) -> CommandResult {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            return .fail("FLASHLIGHT_UNAVAILABLE", "No flashlight on this device.")
        }
        do {
            try device.lockForConfiguration()
            if enabled {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            return CommandResult(success: true, data: ["flashlight": enabled ? "on" : "off"])
        } catch {
            return .fail("FLASHLIGHT_UNAVAILABLE", error.localizedDescription)
        }
    }

    // MARK: - Apps & URLs

    /// iOS cannot enumerate or launch arbitrary apps. We map common app names to their
    /// public URL schemes; anything else may be passed directly as a scheme (e.g. "spotify://").
    private static let knownSchemes: [String: String] = [
        "spotify": "spotify://",
        "youtube": "youtube://",
        "whatsapp": "whatsapp://",
        "instagram": "instagram://",
        "telegram": "tg://",
        "discord": "discord://",
        "twitter": "twitter://",
        "x": "twitter://",
        "facebook": "fb://",
        "messenger": "fb-messenger://",
        "gmail": "googlegmail://",
        "google maps": "comgooglemaps://",
        "maps": "maps://",
        "netflix": "nflx://",
        "safari": "x-web-search://",
        "settings": "app-settings:",
        "phone": "tel://",
        "messages": "sms://",
        "mail": "mailto:",
        "music": "music://",
        "photos": "photos-redirect://",
        "camera": "camera://",
        "calendar": "calshow://",
        "notes": "mobilenotes://",
        "facetime": "facetime://",
        "app store": "itms-apps://",
    ]

    private func launchApp(_ parameters: [String: Any]) -> CommandResult {
        let requested = ["package", "package_name", "app_name", "app", "name"]
            .lazy.compactMap { parameters[$0] }.first
            .map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !requested.isEmpty else {
            return .fail("INVALID_ARGUMENT", "App name or URL scheme is required.")
        }
        let scheme = requested.contains(":") ? requested : Self.knownSchemes[requested.lowercased()]
        guard let scheme, let url = URL(string: scheme) else {
            return .fail("APP_NOT_FOUND", "iOS cannot launch '\(requested)' by name. Pass its URL scheme instead (for example \"spotify://\").")
        }
        UIApplication.shared.open(url)
        return CommandResult(success: true, data: ["url_scheme": scheme, "app_name": requested])
    }

    private func openUrl(_ parameters: [String: Any]) -> CommandResult {
        let raw = (parameters["url"]).map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !raw.isEmpty else { return .fail("INVALID_ARGUMENT", "URL is required.") }
        let normalized = raw.contains("://") || raw.hasPrefix("mailto:") || raw.hasPrefix("tel:") ? raw : "https://\(raw)"
        guard let url = URL(string: normalized) else { return .fail("OPEN_URL_FAILED", "Invalid URL: \(raw)") }
        UIApplication.shared.open(url)
        return CommandResult(success: true, data: ["url": normalized])
    }

    // MARK: - Volume

    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))

    /// The system volume slider has to live in the view hierarchy to take effect.
    func attachVolumeView(to window: UIWindow?) {
        guard let window, volumeView.superview == nil else { return }
        volumeView.alpha = 0.01
        window.addSubview(volumeView)
    }

    private func volumeGet() -> CommandResult {
        try? AVAudioSession.sharedInstance().setActive(true)
        let percentage = Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded())
        return CommandResult(success: true, data: ["stream": "music", "percentage": percentage, "current": percentage, "max": 100])
    }

    private func volumeSet(_ parameters: [String: Any]) -> CommandResult {
        guard let raw = parameters["level"] ?? parameters["volume"] ?? parameters["percentage"] ?? parameters["value"] else {
            return .fail("INVALID_ARGUMENT", "Volume value is required.")
        }
        guard let value = Double("\(raw)".replacingOccurrences(of: "%", with: "")) else {
            return .fail("INVALID_ARGUMENT", "Volume value must be numeric.")
        }
        let clamped = Int(min(100, max(0, value)))
        if volumeView.superview == nil {
            attachVolumeView(to: UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        }
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else {
            return .fail("AUDIO_UNAVAILABLE", "System volume control unavailable.")
        }
        slider.value = Float(clamped) / 100
        slider.sendActions(for: .valueChanged)
        return CommandResult(success: true, data: ["stream": "music", "percentage": clamped, "current": clamped, "max": 100])
    }

    // MARK: - Files (sandboxed to the app's Documents folder, visible in the Files app)

    private var documentsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func resolveFileTarget(_ path: Any?) -> URL {
        let root = documentsRoot
        let raw = path.map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if raw.isEmpty || ["home", "documents"].contains(raw.lowercased()) { return root }
        let named = ["downloads": "Downloads", "pictures": "Pictures", "music": "Music", "movies": "Movies", "videos": "Movies"]
        if let folder = named[raw.lowercased()] {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // Keep every path inside the sandbox root.
        let relative = raw.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
        return root.appendingPathComponent(relative)
    }

    private func fileList(_ parameters: [String: Any]) -> CommandResult {
        let dir = resolveFileTarget(parameters["path"])
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return .fail("NOT_FOUND", "Directory not found: \(dir.path)")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        let items: [[String: Any]] = contents.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return [
                "name": url.lastPathComponent,
                "is_dir": values?.isDirectory ?? false,
                "size": values?.fileSize ?? 0,
                "path": url.path,
            ]
        }
        return CommandResult(success: true, data: ["items": items, "path": dir.path])
    }

    private func fileRead(_ parameters: [String: Any]) -> CommandResult {
        let file = resolveFileTarget(parameters["path"])
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
            return .fail("NOT_FOUND", "File not found: \(file.path)")
        }
        do {
            let content = try String(contentsOf: file, encoding: .utf8)
            return CommandResult(success: true, data: ["content": content, "path": file.path])
        } catch {
            return .fail("READ_ERROR", error.localizedDescription)
        }
    }

    private func fileWrite(_ parameters: [String: Any]) -> CommandResult {
        let file = resolveFileTarget(parameters["path"])
        let content = parameters["content"].map { "\($0)" } ?? ""
        let append = (parameters["append"] as? Bool) ?? false
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append, let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(content.utf8))
            } else {
                try content.write(to: file, atomically: true, encoding: .utf8)
            }
            return CommandResult(success: true, data: ["message": "File written successfully.", "path": file.path])
        } catch {
            return .fail("WRITE_ERROR", error.localizedDescription)
        }
    }

    private func fileDelete(_ parameters: [String: Any]) -> CommandResult {
        let file = resolveFileTarget(parameters["path"])
        guard file.standardizedFileURL != documentsRoot.standardizedFileURL else {
            return .fail("DELETE_FAILED", "Refusing to delete the root folder.")
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .fail("NOT_FOUND", "File or directory not found: \(file.path)")
        }
        do {
            try FileManager.default.removeItem(at: file)
            return CommandResult(success: true, data: ["message": "Deleted successfully.", "path": file.path])
        } catch {
            return .fail("DELETE_ERROR", error.localizedDescription)
        }
    }
}

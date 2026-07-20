import Foundation
import SwiftUI
import Combine
import UIKit
import UniformTypeIdentifiers

enum InputMode: Int, CaseIterable, Identifiable {
    case keyboard = 0
    case joystick = 1
    case touch    = 2     // hidden overlay, just touch the screen
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .joystick: return "Joystick"
        case .touch:    return "Touch"
        }
    }
    var icon: String {
        switch self {
        case .keyboard: return "keyboard"
        case .joystick: return "gamecontroller"
        case .touch:    return "hand.tap"
        }
    }
}

/// ObservableObject that wraps the EmulatorBridge for SwiftUI consumption.
final class EmulatorController: ObservableObject {

    static let shared = EmulatorController()

    let bridge = EmulatorBridge.shared()

    @Published var inputMode: InputMode = .keyboard
    @Published var mountedDiskNames: [Int: String] = [:]

    var isRunning: Bool = false
    var isPaused: Bool = false
    var currentMHz: Float = 0.0

    var saveStates: [SaveState] = []
    private var mountedDisksStorage: [Int: URL] = [:]

    func mountedDisk(for slot: GSDiskSlot) -> URL? {
        mountedDisksStorage[slot.rawValue]
    }

    var mountedDisks: [GSDiskSlot: URL] {
        var out: [GSDiskSlot: URL] = [:]
        for (k, v) in mountedDisksStorage {
            if let s = GSDiskSlot(rawValue: k) { out[s] = v }
        }
        return out
    }

    struct SaveState: Identifiable, Hashable {
        let id: UUID
        let name: String
        let date: Date
        let url: URL
        let thumbnailURL: URL?
    }

    private var statsTimer: Timer?
    private var didBootstrap = false

    private init() {
        // Intentionally empty. Call bootstrap() from an onAppear instead.
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Mount the default disk *before* starting the emulator so the //GS
        // can boot from it instead of falling through to the BASIC prompt.
        loadDefaultDiskIfNeeded()
        startEmulator()
        refreshSaveStates()

        // The //GS may have already started executing its boot ROM before the
        // pending disk-insert reached the IWM. Issue a cold boot once the
        // emulator thread has settled to force a fresh slot scan.
        if !mountedDisksStorage.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.bridge.coldBoot()
            }
        }

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.currentMHz = self.bridge.currentMHz
                self.isRunning  = self.bridge.isRunning
            }
        }
    }

    // MARK: - Lifecycle

    func startEmulator() {
        bridge.start()
        isRunning = true
    }

    func pauseOrResume() {
        if bridge.isRunning {
            bridge.pause()
            isPaused = true
        } else {
            bridge.resume()
            isPaused = false
        }
        isRunning = bridge.isRunning
    }

    func reset() { bridge.reset() }
    func coldBoot() { bridge.coldBoot() }

    // MARK: - Disk

    private func loadDefaultDiskIfNeeded() {
        // Restore any previously-mounted disks from Documents/Disks first.
        restoreMountedDisks()

        // If S5D1 is still empty, mount the bundled Nucleus.2mg so the user
        // boots into something rather than the BASIC prompt. The disk lives
        // in the "Disks" subdirectory inside the bundle.
        if mountedDisksStorage[GSDiskSlot.s5D1.rawValue] == nil {
            let url = Bundle.main.url(forResource: "Nucleus", withExtension: "2mg", subdirectory: "Disks")
                ?? Bundle.main.url(forResource: "Nucleus", withExtension: "2mg")
            if let url {
                _ = mountDisk(url: url, slot: .s5D1)
            }
        }
    }

    private func restoreMountedDisks() {
        guard let dict = UserDefaults.standard.dictionary(forKey: "MountedDisks") as? [String: String] else { return }
        for (slotStr, name) in dict {
            guard let slotRaw = Int(slotStr),
                  let slot = GSDiskSlot(rawValue: slotRaw) else { continue }
            let url = diskDocumentsDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            ensureDownloaded(url)
            if bridge.insertDisk(atPath: url.path, slot: slot) {
                mountedDisksStorage[slotRaw] = url
                mountedDiskNames[slotRaw] = name
            }
        }
    }

    @discardableResult
    func mountDisk(url: URL, slot: GSDiskSlot) -> Bool {
        // Copy into our Documents/Disks (iCloud-backed when available) so the
        // path is stable and the file syncs to the user's other devices.
        let dest = diskDocumentsDirectory.appendingPathComponent(url.lastPathComponent)
        if url.path != dest.path {
            try? FileManager.default.createDirectory(at: diskDocumentsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            let secure = url.startAccessingSecurityScopedResource()
            defer { if secure { url.stopAccessingSecurityScopedResource() } }
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        ensureDownloaded(dest)
        let ok = bridge.insertDisk(atPath: dest.path, slot: slot)
        if ok {
            mountedDisksStorage[slot.rawValue] = dest
            mountedDiskNames[slot.rawValue] = dest.lastPathComponent
            persistMountedDisks()
        }
        return ok
    }

    /// If `url` is an iCloud placeholder (synced metadata but no content yet),
    /// kick off the download and block briefly so the caller can fopen it.
    /// No-op for local files.
    private func ensureDownloaded(_ url: URL) {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let s = try? url.resourceValues(forKeys: keys).ubiquitousItemDownloadingStatus, s == .current {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func ejectDisk(slot: GSDiskSlot) {
        bridge.ejectDisk(slot)
        mountedDisksStorage.removeValue(forKey: slot.rawValue)
        mountedDiskNames.removeValue(forKey: slot.rawValue)
        persistMountedDisks()
    }

    func importDiskImage(from url: URL) {
        _ = mountDisk(url: url, slot: .s5D1)
    }

    // MARK: - Save state

    func saveCurrentState(named name: String) {
        let id = UUID()
        let url = savesDirectory.appendingPathComponent("\(id.uuidString).gsstate")
        try? FileManager.default.createDirectory(at: savesDirectory, withIntermediateDirectories: true)
        let ok = bridge.saveState(toPath: url.path)
        guard ok else { return }

        // Save thumbnail
        var thumbURL: URL? = nil
        if let uiImage = bridge.snapshotImage() {
            let thumb = savesDirectory.appendingPathComponent("\(id.uuidString).png")
            if let pngData = uiImage.pngData() {
                try? pngData.write(to: thumb)
                thumbURL = thumb
            }
        }

        let meta = SaveState(id: id, name: name, date: Date(), url: url, thumbnailURL: thumbURL)
        saveStates.insert(meta, at: 0)
        persistSaveStateMetadata()
    }

    func loadSaveState(_ state: SaveState) {
        _ = bridge.loadState(fromPath: state.url.path)
    }

    func deleteSaveState(_ state: SaveState) {
        try? FileManager.default.removeItem(at: state.url)
        if let thumb = state.thumbnailURL {
            try? FileManager.default.removeItem(at: thumb)
        }
        saveStates.removeAll { $0.id == state.id }
        persistSaveStateMetadata()
    }

    // MARK: - Input

    func sendText(_ s: String) {
        bridge.typeText(s)
    }

    func sendKey(adb: Int32) {
        bridge.keyDown(adb)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.bridge.keyUp(adb)
        }
    }

    func setJoystick(x: Float, y: Float) {
        bridge.setJoystickX(x, y: y)
    }

    func setJoystickButton(_ button: Int32, pressed: Bool) {
        bridge.setJoystickButton(button, pressed: pressed)
    }

    // MARK: - Persistence

    /// iCloud Drive's Documents folder for this app, or `nil` when iCloud isn't
    /// available (user not signed in, capability missing, simulator without
    /// account). Resolved once on first access — `url(forUbiquityContainerIdentifier:)`
    /// can block, so callers should hit this off the main thread when possible.
    private lazy var iCloudDocumentsDirectory: URL? = {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }()

    var iCloudAvailable: Bool { iCloudDocumentsDirectory != nil }

    /// Public so the UI can list and `onChange`-monitor what's in the disk library.
    var disksDirectory: URL { diskDocumentsDirectory }

    private var diskDocumentsDirectory: URL {
        let root = iCloudDocumentsDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("Disks", isDirectory: true)
    }

    private var savesDirectory: URL {
        let root = iCloudDocumentsDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("SaveStates", isDirectory: true)
    }

    private func persistMountedDisks() {
        var strs: [String: String] = [:]
        for (k, v) in mountedDisksStorage {
            strs[String(k)] = v.lastPathComponent
        }
        UserDefaults.standard.set(strs, forKey: "MountedDisks")
    }

    private func persistSaveStateMetadata() {
        let array = saveStates.map { st -> [String: Any] in
            [
                "id": st.id.uuidString,
                "name": st.name,
                "date": st.date.timeIntervalSince1970,
                "file": st.url.lastPathComponent,
                "thumb": st.thumbnailURL?.lastPathComponent ?? ""
            ]
        }
        UserDefaults.standard.set(array, forKey: "SaveStates")
    }

    private func refreshSaveStates() {
        guard let array = UserDefaults.standard.array(forKey: "SaveStates") as? [[String: Any]] else { return }
        var states: [SaveState] = []
        for d in array {
            guard let idStr = d["id"] as? String, let id = UUID(uuidString: idStr),
                  let name = d["name"] as? String,
                  let dateTI = d["date"] as? TimeInterval,
                  let file = d["file"] as? String else { continue }
            let url = savesDirectory.appendingPathComponent(file)
            let thumb = (d["thumb"] as? String).flatMap { $0.isEmpty ? nil : savesDirectory.appendingPathComponent($0) }
            states.append(SaveState(id: id, name: name, date: Date(timeIntervalSince1970: dateTI), url: url, thumbnailURL: thumb))
        }
        saveStates = states
    }
}

extension GSDiskSlot: CaseIterable, Identifiable {
    public static var allCases: [GSDiskSlot] {
        [.s5D1, .s5D2, .s6D1, .s6D2, .s7D1, .s7D2]
    }
    public var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .s5D1: return "3.5\" S5 D1"
        case .s5D2: return "3.5\" S5 D2"
        case .s6D1: return "5.25\" S6 D1"
        case .s6D2: return "5.25\" S6 D2"
        case .s7D1: return "HD/Smart D1"
        case .s7D2: return "HD/Smart D2"
        @unknown default: return "Unknown"
        }
    }
}

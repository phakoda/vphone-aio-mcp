@preconcurrency import AppKit
import Foundation
import MCP
@preconcurrency import Virtualization
import VPhoneObjC

private let vphoneDisplayWidth = 1290
private let vphoneDisplayHeight = 2796

let vphoneMCPDebugEnabled = ProcessInfo.processInfo.environment["VPHONE_MCP_DEBUG"] == "1"

func vphoneMCPDebug(_ message: @autoclosure () -> String) {
    guard vphoneMCPDebugEnabled else { return }
    FileHandle.standardError.write(Data(("[vphone-mcp-debug] " + message() + "\n").utf8))
}

enum VPhoneMCPError: LocalizedError {
    case vmAlreadyRunning
    case vmNotRunning
    case vmAssetsNotFound
    case missingFile(String)
    case screenshotUnavailable
    case touchUnavailable
    case invalidArgument(String)
    case shutdownFailed(String)

    var errorDescription: String? {
        switch self {
        case .vmAlreadyRunning:
            "The VM is already running. Stop it before starting a new session."
        case .vmNotRunning:
            "The VM is not running."
        case .vmAssetsNotFound:
            "Could not locate the VM assets directory. Pass `vm_dir` or explicit file paths."
        case .missingFile(let path):
            "Required file not found: \(path)"
        case .screenshotUnavailable:
            "Could not capture a screenshot from the VM display."
        case .touchUnavailable:
            "Touch input is not available yet. Wait for the display to finish initializing and try again."
        case .invalidArgument(let message):
            message
        case .shutdownFailed(let message):
            message
        }
    }
}

struct VMStatusPayload: Codable, Sendable {
    let running: Bool
    let state: String
    let startedAt: String?
    let showWindow: Bool
    let vmDirectory: String?
    let romPath: String?
    let diskPath: String?
    let nvramPath: String?
    let sepStoragePath: String?
    let sepRomPath: String?
    let cpu: Int?
    let memoryMB: Int?
    let displayWidth: Int
    let displayHeight: Int
}

struct ScreenshotPayload: Codable, Sendable {
    let width: Int
    let height: Int
    let mimeType: String
}

struct GesturePayload: Codable, Sendable {
    let action: String
    let x: Double?
    let y: Double?
    let fromX: Double?
    let fromY: Double?
    let toX: Double?
    let toY: Double?
    let durationMs: Int?
    let steps: Int?
}

struct StartVMArguments {
    let vmDir: String?
    let romPath: String?
    let diskPath: String?
    let nvramPath: String?
    let sepStoragePath: String?
    let sepRomPath: String?
    let cpu: Int
    let memoryMB: Int
    let showWindow: Bool
    let skipSEP: Bool
    let stopOnPanic: Bool
    let stopOnFatalError: Bool
}

struct ResolvedVMPaths: Sendable {
    let vmDirectory: String?
    let romPath: String
    let diskPath: String
    let nvramPath: String
    let sepStoragePath: String?
    let sepRomPath: String?
}

private enum VPhoneHardware {
    static func createModel() throws -> VZMacHardwareModel {
        let model = VPhoneCreateHardwareModel()
        guard model.isSupported else {
            throw VPhoneError.hardwareModelNotSupported
        }
        return model
    }
}

private enum VPhoneError: LocalizedError, CustomStringConvertible {
    case hardwareModelNotSupported

    var description: String {
        """
        PV=3 hardware model not supported. Check:
          1. macOS >= 15.0 (Sequoia)
          2. Signed with com.apple.private.virtualization + com.apple.private.virtualization.security-research
          3. SIP/AMFI disabled
        """
    }

    var errorDescription: String? {
        description
    }
}

@MainActor
final class MCPVPhoneVM: NSObject, @preconcurrency VZVirtualMachineDelegate {
    struct Options {
        let romURL: URL
        let nvramURL: URL
        let diskURL: URL
        let cpuCount: Int
        let memorySize: UInt64
        let skipSEP: Bool
        let sepStorageURL: URL?
        let sepRomURL: URL?
        let stopOnPanic: Bool
        let stopOnFatalError: Bool
    }

    let virtualMachine: VZVirtualMachine

    private(set) var didStop = false
    private(set) var lastStopError: String?

    init(options: Options) throws {
        let hwModel = try VPhoneHardware.createModel()
        let platform = VZMacPlatformConfiguration()

        let machineIDPath = options.nvramURL.deletingLastPathComponent()
            .appendingPathComponent("machineIdentifier.bin")
        if let savedData = try? Data(contentsOf: machineIDPath),
            let savedID = VZMacMachineIdentifier(dataRepresentation: savedData)
        {
            platform.machineIdentifier = savedID
        } else {
            let newID = VZMacMachineIdentifier()
            platform.machineIdentifier = newID
            try newID.dataRepresentation.write(to: machineIDPath)
        }

        let auxStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: options.nvramURL,
            hardwareModel: hwModel,
            options: .allowOverwrite
        )
        platform.auxiliaryStorage = auxStorage
        platform.hardwareModel = hwModel

        let bootArgs =
            "serial=00 debug=0x104c04 cs_enforcement_disable=1 amfi_allow_any_signature=1 txm_cs_disable=1 amfi=0x8f"
        if let bootArgsData = bootArgs.data(using: .utf8) {
            _ = VPhoneSetNVRAMVariable(auxStorage, "boot-args", bootArgsData)
        }

        let bootloader = VZMacOSBootLoader()
        VPhoneSetBootLoaderROMURL(bootloader, options.romURL)

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = bootloader
        config.platform = platform
        config.cpuCount = max(
            options.cpuCount,
            VZVirtualMachineConfiguration.minimumAllowedCPUCount
        )
        config.memorySize = max(
            options.memorySize,
            VZVirtualMachineConfiguration.minimumAllowedMemorySize
        )

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: vphoneDisplayWidth,
                heightInPixels: vphoneDisplayHeight,
                pixelsPerInch: 460
            )
        ]
        config.graphicsDevices = [graphics]

        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: options.diskURL,
            readOnly: false
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        VPhoneConfigureMultiTouch(config)
        VPhoneConfigureUSBKeyboard(config)
        VPhoneSetGDBDebugStubDefault(config)

        if options.skipSEP {
            VPhoneSetCoprocessors(config, [])
        } else if let sepStorageURL = options.sepStorageURL {
            VPhoneConfigureSEP(config, sepStorageURL, options.sepRomURL)
        }

        try config.validate()

        virtualMachine = VZVirtualMachine(configuration: config)
        super.init()
        virtualMachine.delegate = self
    }

    var stateDescription: String {
        switch virtualMachine.state {
        case .stopped:
            "stopped"
        case .running:
            "running"
        case .paused:
            "paused"
        case .error:
            "error"
        case .starting:
            "starting"
        case .pausing:
            "pausing"
        case .resuming:
            "resuming"
        case .stopping:
            "stopping"
        case .saving:
            "saving"
        case .restoring:
            "restoring"
        @unknown default:
            "unknown"
        }
    }

    var isInteractive: Bool {
        switch virtualMachine.state {
        case .running, .paused, .starting, .resuming:
            true
        default:
            false
        }
    }

    func start(forceDFU: Bool = false) async throws {
        vphoneMCPDebug("MCPVPhoneVM.start enter")
        let options = VZMacOSVirtualMachineStartOptions()
        VPhoneConfigureStartOptions(
            options,
            forceDFU,
            false,
            false
        )
        didStop = false
        lastStopError = nil
        try await virtualMachine.start(options: options)
        vphoneMCPDebug("MCPVPhoneVM.start returned state=\(stateDescription)")
    }

    func requestShutdown() async throws {
        if virtualMachine.state == .stopped {
            didStop = true
            return
        }

        if virtualMachine.canRequestStop {
            do {
                try virtualMachine.requestStop()
                if await waitForStop(timeout: .seconds(5)) {
                    return
                }
            } catch {
                // Fall through to force stop if the guest did not accept a graceful shutdown.
            }
        }

        guard virtualMachine.canStop else {
            throw VPhoneMCPError.shutdownFailed(
                "The VM cannot be stopped from its current state (\(stateDescription))."
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            virtualMachine.stop { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    self.didStop = true
                    continuation.resume()
                }
            }
        }
    }

    func waitForStop(timeout: Duration) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if didStop || virtualMachine.state == .stopped {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return virtualMachine.state == .stopped
    }

    func tap(at point: CGPoint, holdDuration: Duration) async throws {
        let swipeAim = edgeCode(for: point)
        let beganAt = ProcessInfo.processInfo.systemUptime
        try sendTouches([(0, 0, point, swipeAim, beganAt)])
        if holdDuration > .zero {
            try await Task.sleep(for: holdDuration)
        }
        let endedAt = ProcessInfo.processInfo.systemUptime
        try sendTouches([(0, 3, point, swipeAim, endedAt)])
    }

    func swipe(from start: CGPoint, to end: CGPoint, duration: Duration, steps: Int) async throws {
        let clampedSteps = max(2, steps)
        let startedAt = ProcessInfo.processInfo.systemUptime
        try sendTouches([(0, 0, start, edgeCode(for: start), startedAt)])

        let totalNanos = max(0, duration.components.seconds) * 1_000_000_000
            + max(0, duration.components.attoseconds / 1_000_000_000)
        let intervalNanos = clampedSteps > 1 ? totalNanos / Int64(clampedSteps - 1) : 0

        for step in 1..<(clampedSteps - 1) {
            if intervalNanos > 0 {
                try? await Task.sleep(nanoseconds: UInt64(intervalNanos))
            }
            let progress = Double(step) / Double(clampedSteps - 1)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            let timestamp = ProcessInfo.processInfo.systemUptime
            try sendTouches([(0, 1, point, edgeCode(for: point), timestamp)])
        }

        if intervalNanos > 0 {
            try? await Task.sleep(nanoseconds: UInt64(intervalNanos))
        }
        let endedAt = ProcessInfo.processInfo.systemUptime
        try sendTouches([(0, 3, end, edgeCode(for: end), endedAt)])
    }

    private func sendTouches(_ touches: [(Int, Int, CGPoint, Int, TimeInterval)]) throws {
        guard let devices = VPhoneGetMultiTouchDevices(virtualMachine), !devices.isEmpty else {
            throw VPhoneMCPError.touchUnavailable
        }

        let objcTouches = try touches.map { index, phase, location, swipeAim, timestamp in
            guard let touch = VPhoneCreateTouch(index, phase, location, swipeAim, timestamp) else {
                throw VPhoneMCPError.touchUnavailable
            }
            return touch
        }

        guard let event = VPhoneCreateMultiTouchEvent(objcTouches) else {
            throw VPhoneMCPError.touchUnavailable
        }

        VPhoneSendMultiTouchEvents(devices[0], [event])
    }

    private func edgeCode(for point: CGPoint) -> Int {
        let threshold = 0.025
        let left = point.x
        let right = 1.0 - point.x
        let top = point.y
        let bottom = 1.0 - point.y

        let candidates: [(CGFloat, Int)] = [
            (left, 8),
            (right, 4),
            (top, 1),
            (bottom, 2),
        ]

        guard let nearest = candidates.min(by: { $0.0 < $1.0 }), nearest.0 < threshold else {
            return 0
        }
        return nearest.1
    }

    func guestDidStop(_: VZVirtualMachine) {
        vphoneMCPDebug("delegate guestDidStop")
        didStop = true
    }

    func virtualMachine(_: VZVirtualMachine, didStopWithError error: any Error) {
        vphoneMCPDebug("delegate didStopWithError=\(error.localizedDescription)")
        didStop = true
        lastStopError = error.localizedDescription
    }

    func virtualMachine(
        _: VZVirtualMachine,
        networkDevice _: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        vphoneMCPDebug("delegate network disconnect=\(error.localizedDescription)")
        lastStopError = error.localizedDescription
    }
}

@MainActor
final class VPhoneDisplayController {
    let view: VZVirtualMachineView
    private let window: NSWindow
    private(set) var isVisible = true
    private(set) var isAttached = false

    init() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()

        view = VZVirtualMachineView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 15.0, *) {
            view.capturesSystemKeys = true
        }

        let windowSize = NSSize(width: 1179, height: 2556)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "vphone-mcp"
        window.contentAspectRatio = windowSize

        let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window.contentView = contentView
    }

    func attach(virtualMachine: VZVirtualMachine, visible: Bool) {
        view.virtualMachine = virtualMachine
        isAttached = true
        setWindowVisibility(visible)
    }

    func setWindowVisibility(_ visible: Bool) {
        isVisible = visible
        if visible {
            window.setFrameOrigin(NSPoint(x: 80, y: 80))
        } else {
            window.setFrameOrigin(NSPoint(x: -2200, y: 80))
        }
        window.orderFront(nil)
    }

    func capturePNG() throws -> Data {
        window.displayIfNeeded()
        view.displayIfNeeded()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw VPhoneMCPError.screenshotUnavailable
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw VPhoneMCPError.screenshotUnavailable
        }
        return pngData
    }

    func close() {
        window.orderOut(nil)
        view.virtualMachine = nil
        isAttached = false
    }
}

actor VPhoneSessionController {
    private struct Session {
        let vm: MCPVPhoneVM
        let display: VPhoneDisplayController
        let startedAt: Date
        let showWindow: Bool
        let paths: ResolvedVMPaths
        let cpu: Int
        let memoryMB: Int
    }

    private var session: Session?
    private var uiPumpTask: Task<Void, Never>?

    func prepareUI() async {
        guard uiPumpTask == nil else { return }

        uiPumpTask = Task { @MainActor in
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.finishLaunching()

            while !Task.isCancelled {
                autoreleasepool {
                    while let event = NSApplication.shared.nextEvent(
                        matching: .any,
                        until: Date(),
                        inMode: .default,
                        dequeue: true
                    ) {
                        NSApplication.shared.sendEvent(event)
                    }
                    NSApplication.shared.updateWindows()
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func shutdown() async {
        if let session {
            _ = try? await session.vm.requestShutdown()
            await session.display.close()
            self.session = nil
        }

        uiPumpTask?.cancel()
        uiPumpTask = nil
    }

    func status() async -> VMStatusPayload {
        guard let session else {
            return VMStatusPayload(
                running: false,
                state: "idle",
                startedAt: nil,
                showWindow: false,
                vmDirectory: nil,
                romPath: nil,
                diskPath: nil,
                nvramPath: nil,
                sepStoragePath: nil,
                sepRomPath: nil,
                cpu: nil,
                memoryMB: nil,
                displayWidth: vphoneDisplayWidth,
                displayHeight: vphoneDisplayHeight
            )
        }

        return VMStatusPayload(
            running: await session.vm.isInteractive,
            state: await session.vm.stateDescription,
            startedAt: ISO8601DateFormatter().string(from: session.startedAt),
            showWindow: session.showWindow,
            vmDirectory: session.paths.vmDirectory,
            romPath: session.paths.romPath,
            diskPath: session.paths.diskPath,
            nvramPath: session.paths.nvramPath,
            sepStoragePath: session.paths.sepStoragePath,
            sepRomPath: session.paths.sepRomPath,
            cpu: session.cpu,
            memoryMB: session.memoryMB,
            displayWidth: vphoneDisplayWidth,
            displayHeight: vphoneDisplayHeight
        )
    }

    func start(arguments: StartVMArguments) async throws -> VMStatusPayload {
        vphoneMCPDebug("runtime.start begin")
        if let existing = session, await existing.vm.virtualMachine.state != .stopped {
            throw VPhoneMCPError.vmAlreadyRunning
        }

        if let existing = session {
            await existing.display.close()
            session = nil
        }

        await prepareUI()

        let paths = try Self.resolvePaths(from: arguments)
        vphoneMCPDebug("runtime.start resolved paths vmDir=\(paths.vmDirectory ?? "nil")")
        let vm = try await MainActor.run {
            try MCPVPhoneVM(
                options: .init(
                    romURL: URL(fileURLWithPath: paths.romPath),
                    nvramURL: URL(fileURLWithPath: paths.nvramPath),
                    diskURL: URL(fileURLWithPath: paths.diskPath),
                    cpuCount: arguments.cpu,
                    memorySize: UInt64(arguments.memoryMB) * 1024 * 1024,
                    skipSEP: arguments.skipSEP,
                    sepStorageURL: paths.sepStoragePath.map { URL(fileURLWithPath: $0) },
                    sepRomURL: paths.sepRomPath.map { URL(fileURLWithPath: $0) },
                    stopOnPanic: arguments.stopOnPanic,
                    stopOnFatalError: arguments.stopOnFatalError
                )
            )
        }
        vphoneMCPDebug("runtime.start created VM object")

        try await vm.start()
        vphoneMCPDebug("runtime.start vm.start completed")

        let display = await MainActor.run { VPhoneDisplayController() }
        vphoneMCPDebug("runtime.start created display controller")

        session = Session(
            vm: vm,
            display: display,
            startedAt: Date(),
            showWindow: arguments.showWindow,
            paths: paths,
            cpu: arguments.cpu,
            memoryMB: arguments.memoryMB
        )
        vphoneMCPDebug("runtime.start session stored")

        return await status()
    }

    func stop() async throws -> VMStatusPayload {
        guard let session else {
            throw VPhoneMCPError.vmNotRunning
        }

        try await session.vm.requestShutdown()
        await session.display.close()
        self.session = nil
        return await status()
    }

    func screenshot(waitMilliseconds: Int) async throws -> (ScreenshotPayload, Data) {
        guard let session else {
            throw VPhoneMCPError.vmNotRunning
        }

        if waitMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(waitMilliseconds))
        }

        if !(await session.display.isAttached) {
            await session.display.attach(
                virtualMachine: session.vm.virtualMachine,
                visible: session.showWindow
            )
            vphoneMCPDebug("runtime.screenshot attached display visible=\(session.showWindow)")
        }

        let pngData = try await MainActor.run {
            try session.display.capturePNG()
        }
        return (
            ScreenshotPayload(
                width: vphoneDisplayWidth,
                height: vphoneDisplayHeight,
                mimeType: "image/png"
            ),
            pngData
        )
    }

    func tap(x: Double, y: Double, holdMilliseconds: Int) async throws -> GesturePayload {
        guard let session else {
            throw VPhoneMCPError.vmNotRunning
        }

        let point = try Self.normalizedPoint(x: x, y: y)
        try await session.vm.tap(
            at: point,
            holdDuration: .milliseconds(max(0, holdMilliseconds))
        )
        return GesturePayload(
            action: "tap",
            x: x,
            y: y,
            fromX: nil,
            fromY: nil,
            toX: nil,
            toY: nil,
            durationMs: holdMilliseconds,
            steps: nil
        )
    }

    func swipe(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMilliseconds: Int,
        steps: Int
    ) async throws -> GesturePayload {
        guard let session else {
            throw VPhoneMCPError.vmNotRunning
        }

        let start = try Self.normalizedPoint(x: fromX, y: fromY)
        let end = try Self.normalizedPoint(x: toX, y: toY)
        try await session.vm.swipe(
            from: start,
            to: end,
            duration: .milliseconds(max(0, durationMilliseconds)),
            steps: max(2, steps)
        )
        return GesturePayload(
            action: "swipe",
            x: nil,
            y: nil,
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            durationMs: durationMilliseconds,
            steps: steps
        )
    }

    private static func normalizedPoint(x: Double, y: Double) throws -> CGPoint {
        guard (0.0...1.0).contains(x), (0.0...1.0).contains(y) else {
            throw VPhoneMCPError.invalidArgument(
                "Coordinates must be normalized values between 0.0 and 1.0."
            )
        }
        return CGPoint(x: x, y: y)
    }

    private static func resolvePaths(from arguments: StartVMArguments) throws -> ResolvedVMPaths {
        let fileManager = FileManager.default
        let baseDirectory = arguments.vmDir
            .map { expandPath($0) }
            ?? discoverVMDirectory()

        func resolve(_ explicitPath: String?, defaultName: String?) -> String? {
            if let explicitPath {
                return expandPath(explicitPath)
            }
            guard let baseDirectory, let defaultName else {
                return nil
            }
            return (baseDirectory as NSString).appendingPathComponent(defaultName)
        }

        guard
            let romPath = resolve(arguments.romPath, defaultName: "AVPBooter.vresearch1.bin"),
            let diskPath = resolve(arguments.diskPath, defaultName: "Disk.img"),
            let nvramPath = resolve(arguments.nvramPath, defaultName: "nvram.bin")
        else {
            throw VPhoneMCPError.vmAssetsNotFound
        }

        guard fileManager.fileExists(atPath: romPath) else {
            throw VPhoneMCPError.missingFile(romPath)
        }
        guard fileManager.fileExists(atPath: diskPath) else {
            throw VPhoneMCPError.missingFile(diskPath)
        }

        let sepStoragePath: String?
        let sepRomPath: String?
        if arguments.skipSEP {
            sepStoragePath = nil
            sepRomPath = nil
        } else {
            sepStoragePath = resolve(arguments.sepStoragePath, defaultName: "SEPStorage")
            sepRomPath = resolve(arguments.sepRomPath, defaultName: "AVPSEPBooter.vresearch1.bin")
            if let sepRomPath, !fileManager.fileExists(atPath: sepRomPath) {
                throw VPhoneMCPError.missingFile(sepRomPath)
            }
        }

        if let nvramDir = (nvramPath as NSString).deletingLastPathComponent as String?,
            !nvramDir.isEmpty
        {
            try fileManager.createDirectory(
                atPath: nvramDir,
                withIntermediateDirectories: true
            )
        }

        return ResolvedVMPaths(
            vmDirectory: baseDirectory,
            romPath: romPath,
            diskPath: diskPath,
            nvramPath: nvramPath,
            sepStoragePath: sepStoragePath,
            sepRomPath: sepRomPath
        )
    }

    private static func discoverVMDirectory() -> String? {
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        var searchRoots = [currentDirectory]

        if let executableURL = Bundle.main.executableURL {
            searchRoots.append(executableURL.deletingLastPathComponent())
        }

        var candidates: [URL] = []
        for root in searchRoots {
            var current: URL? = root
            while let url = current {
                candidates.append(url)
                current = url.deletingLastPathComponent() == url ? nil : url.deletingLastPathComponent()
            }
        }

        for candidate in candidates {
            let directVM = candidate.appendingPathComponent("VM", isDirectory: true)
            if fileManager.fileExists(atPath: directVM.appendingPathComponent("Disk.img").path) {
                return directVM.path
            }

            let nestedVM = candidate.appendingPathComponent("vphone-cli", isDirectory: true)
                .appendingPathComponent("VM", isDirectory: true)
            if fileManager.fileExists(atPath: nestedVM.appendingPathComponent("Disk.img").path) {
                return nestedVM.path
            }
        }

        return nil
    }

    private static func expandPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

enum VPhoneMCPTools {
    static let all: [Tool] = [
        Tool(
            name: "vphone_status",
            description: "Return the current iPhone VM status and the active asset paths.",
            inputSchema: [
                "type": "object",
                "properties": [:],
            ],
            annotations: .init(
                title: "Get VM status",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ),
        Tool(
            name: "vphone_start",
            description: "Boot the iPhone VM in-process so later tools can capture screenshots and inject touch events.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "vm_dir": [
                        "type": "string",
                        "description": "Optional directory containing VM assets like Disk.img and nvram.bin.",
                    ],
                    "rom_path": [
                        "type": "string",
                        "description": "Optional explicit path to the AVPBooter ROM.",
                    ],
                    "disk_path": [
                        "type": "string",
                        "description": "Optional explicit path to Disk.img.",
                    ],
                    "nvram_path": [
                        "type": "string",
                        "description": "Optional explicit path to nvram.bin.",
                    ],
                    "sep_storage_path": [
                        "type": "string",
                        "description": "Optional explicit path to SEP storage.",
                    ],
                    "sep_rom_path": [
                        "type": "string",
                        "description": "Optional explicit path to the SEP ROM binary.",
                    ],
                    "cpu": [
                        "type": "integer",
                        "description": "vCPU count. Default: 16.",
                    ],
                    "memory_mb": [
                        "type": "integer",
                        "description": "Memory size in MB. Default: 8192.",
                    ],
                    "show_window": [
                        "type": "boolean",
                        "description": "Whether to keep the VM display window visible on the host. Default: true.",
                    ],
                    "skip_sep": [
                        "type": "boolean",
                        "description": "Skip the SEP coprocessor. Default: false.",
                    ],
                    "stop_on_panic": [
                        "type": "boolean",
                        "description": "Reserved for parity with the CLI. Currently accepted but not used.",
                    ],
                    "stop_on_fatal_error": [
                        "type": "boolean",
                        "description": "Reserved for parity with the CLI. Currently accepted but not used.",
                    ],
                ],
            ],
            annotations: .init(
                title: "Start VM",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            )
        ),
        Tool(
            name: "vphone_stop",
            description: "Stop the active iPhone VM session and release its display window.",
            inputSchema: [
                "type": "object",
                "properties": [:],
            ],
            annotations: .init(
                title: "Stop VM",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            )
        ),
        Tool(
            name: "vphone_screenshot",
            description: "Capture the current VM display as a PNG image. Call this before deciding the next touch action.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "wait_ms": [
                        "type": "integer",
                        "description": "Optional delay before the capture to let animations settle. Default: 150.",
                    ],
                ],
            ],
            annotations: .init(
                title: "Capture screenshot",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ),
        Tool(
            name: "vphone_tap",
            description: "Inject a single touch at normalized screen coordinates where (0,0) is top-left and (1,1) is bottom-right.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "x": [
                        "type": "number",
                        "description": "Normalized horizontal coordinate between 0.0 and 1.0.",
                    ],
                    "y": [
                        "type": "number",
                        "description": "Normalized vertical coordinate between 0.0 and 1.0.",
                    ],
                    "hold_ms": [
                        "type": "integer",
                        "description": "Optional press duration in milliseconds. Default: 60.",
                    ],
                ],
                "required": ["x", "y"],
            ],
            annotations: .init(
                title: "Tap screen",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ),
        Tool(
            name: "vphone_swipe",
            description: "Inject a swipe gesture between normalized coordinates.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "from_x": [
                        "type": "number",
                        "description": "Start X coordinate between 0.0 and 1.0.",
                    ],
                    "from_y": [
                        "type": "number",
                        "description": "Start Y coordinate between 0.0 and 1.0.",
                    ],
                    "to_x": [
                        "type": "number",
                        "description": "End X coordinate between 0.0 and 1.0.",
                    ],
                    "to_y": [
                        "type": "number",
                        "description": "End Y coordinate between 0.0 and 1.0.",
                    ],
                    "duration_ms": [
                        "type": "integer",
                        "description": "Gesture duration in milliseconds. Default: 350.",
                    ],
                    "steps": [
                        "type": "integer",
                        "description": "Number of interpolation points. Default: 12.",
                    ],
                ],
                "required": ["from_x", "from_y", "to_x", "to_y"],
            ],
            annotations: .init(
                title: "Swipe screen",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ),
    ]
}

private func jsonText<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
        throw VPhoneMCPError.invalidArgument("Failed to encode result payload.")
    }
    return text
}

enum VPhoneMCPToolHandler {
    static func handle(
        _ params: CallTool.Parameters,
        runtime: VPhoneSessionController
    ) async -> CallTool.Result {
        do {
            vphoneMCPDebug("tool.handle \(params.name) begin")
            switch params.name {
            case "vphone_status":
                let status = await runtime.status()
                return .init(
                    content: [
                        .text("VM state: \(status.state)"),
                        .text(try jsonText(status)),
                    ]
                )

            case "vphone_start":
                let args = try parseStartArguments(params.arguments)
                let status = try await runtime.start(arguments: args)
                return .init(
                    content: [
                        .text("VM started. State: \(status.state)"),
                        .text(try jsonText(status)),
                    ]
                )

            case "vphone_stop":
                let status = try await runtime.stop()
                return .init(
                    content: [
                        .text("VM stopped."),
                        .text(try jsonText(status)),
                    ]
                )

            case "vphone_screenshot":
                let waitMs = value(named: "wait_ms", in: params.arguments)?.intValue ?? 150
                let (payload, pngData) = try await runtime.screenshot(waitMilliseconds: max(0, waitMs))
                return .init(
                    content: [
                        .text("Captured screenshot."),
                        .text(try jsonText(payload)),
                        .image(data: pngData.base64EncodedString(), mimeType: payload.mimeType, metadata: nil),
                    ]
                )

            case "vphone_tap":
                let x = try requiredDouble("x", in: params.arguments)
                let y = try requiredDouble("y", in: params.arguments)
                let holdMs = value(named: "hold_ms", in: params.arguments)?.intValue ?? 60
                let payload = try await runtime.tap(x: x, y: y, holdMilliseconds: holdMs)
                return .init(
                    content: [
                        .text("Tap injected at (\(x), \(y))."),
                        .text(try jsonText(payload)),
                    ]
                )

            case "vphone_swipe":
                let fromX = try requiredDouble("from_x", in: params.arguments)
                let fromY = try requiredDouble("from_y", in: params.arguments)
                let toX = try requiredDouble("to_x", in: params.arguments)
                let toY = try requiredDouble("to_y", in: params.arguments)
                let durationMs = value(named: "duration_ms", in: params.arguments)?.intValue ?? 350
                let steps = value(named: "steps", in: params.arguments)?.intValue ?? 12
                let payload = try await runtime.swipe(
                    fromX: fromX,
                    fromY: fromY,
                    toX: toX,
                    toY: toY,
                    durationMilliseconds: durationMs,
                    steps: steps
                )
                return .init(
                    content: [
                        .text("Swipe injected."),
                        .text(try jsonText(payload)),
                    ]
                )

            default:
                return .init(
                    content: [.text("Unknown tool: \(params.name)")],
                    isError: true
                )
            }
        } catch {
            vphoneMCPDebug("tool.handle \(params.name) error=\(error.localizedDescription)")
            return .init(
                content: [.text(userVisibleMessage(for: error))],
                isError: true
            )
        }
    }

    private static func userVisibleMessage(for error: Error) -> String {
        let text = error.localizedDescription
        let lowercased = text.lowercased()

        if lowercased.contains("failed to lock auxiliary storage")
            || (lowercased.contains("auxiliary storage") && lowercased.contains("already in use"))
        {
            return "The selected `nvram_path` is already locked by another VM process. Stop the other VM or pass a different `nvram_path`."
        }

        return text
    }

    private static func parseStartArguments(_ arguments: [String: Value]?) throws -> StartVMArguments {
        StartVMArguments(
            vmDir: value(named: "vm_dir", in: arguments)?.stringValue,
            romPath: value(named: "rom_path", in: arguments)?.stringValue,
            diskPath: value(named: "disk_path", in: arguments)?.stringValue,
            nvramPath: value(named: "nvram_path", in: arguments)?.stringValue,
            sepStoragePath: value(named: "sep_storage_path", in: arguments)?.stringValue,
            sepRomPath: value(named: "sep_rom_path", in: arguments)?.stringValue,
            cpu: max(1, value(named: "cpu", in: arguments)?.intValue ?? 16),
            memoryMB: max(1024, value(named: "memory_mb", in: arguments)?.intValue ?? 8192),
            showWindow: value(named: "show_window", in: arguments)?.boolValue ?? true,
            skipSEP: value(named: "skip_sep", in: arguments)?.boolValue ?? false,
            stopOnPanic: value(named: "stop_on_panic", in: arguments)?.boolValue ?? false,
            stopOnFatalError: value(named: "stop_on_fatal_error", in: arguments)?.boolValue ?? false
        )
    }

    private static func value(named name: String, in arguments: [String: Value]?) -> Value? {
        arguments?[name]
    }

    private static func requiredDouble(_ name: String, in arguments: [String: Value]?) throws -> Double {
        if let value = value(named: name, in: arguments)?.doubleValue {
            return value
        }
        if let intValue = value(named: name, in: arguments)?.intValue {
            return Double(intValue)
        }
        throw VPhoneMCPError.invalidArgument("Missing required numeric argument: \(name)")
    }
}

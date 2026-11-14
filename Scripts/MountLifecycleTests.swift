// Durable lifecycle regressions against real production sources. The helper is
// a private Python fixture, NOT rclone: no browser, OAuth token, config mutation,
// filesystem mount, installer, or Keychain write is ever performed.
import Darwin
import Foundation

private struct LifecycleFailure: Error, Sendable, CustomStringConvertible {
    let description: String
}

private struct HelperEvent: Decodable, Sendable {
    let pid: Int32
    let ppid: Int32
    let kind: String
}

private struct HelperBehavior: Encodable, Sendable {
    var delayCommand: String?
    var suppressAnnouncement = false
    var pidMismatch = false
    var refreshStatus = 200
    var omitFatalDiagnostic = false
    var pendingWrites = false
    var missingQueue = false
    var exitBeforeReady = false
}

private actor FakeMountInspector: MountInspecting {
    enum Detachment: Sendable { case detach, retain }
    private let pidFile: URL
    private var lastPID: Int32?
    private var attached = false
    private var detachment = Detachment.detach
    private var oneAbsentProbe = false
    private var blockForce = false
    private var blockedForce: CheckedContinuation<Void, Never>?
    private var blockAttachmentProbe = false
    private var blockedAttachmentProbe: CheckedContinuation<Void, Never>?
    private(set) var attachmentProbeIsBlocked = false
    private(set) var forceCalls = 0
    private(set) var forceIsBlocked = false
    private(set) var cancelledObservations: [Bool] = []

    init(pidFile: URL) { self.pidFile = pidFile }

    func isActive(path: String) async -> Bool {
        cancelledObservations.append(Task.isCancelled)
        if let data = try? Data(contentsOf: pidFile),
           let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != lastPID {
            lastPID = pid
            attached = true
            if blockAttachmentProbe {
                attachmentProbeIsBlocked = true
                await withCheckedContinuation { blockedAttachmentProbe = $0 }
                attachmentProbeIsBlocked = false
            }
        }
        if oneAbsentProbe {
            oneAbsentProbe = false
            return false
        }
        return attached
    }

    func unmountIfUnused(path: String) async -> Bool {
        await forceUnmount(path: path)
    }

    func forceUnmount(path: String) async -> Bool {
        cancelledObservations.append(Task.isCancelled)
        forceCalls += 1
        if blockForce {
            forceIsBlocked = true
            await withCheckedContinuation { blockedForce = $0 }
            forceIsBlocked = false
        }
        switch detachment {
        case .detach:
            attached = false
            return true
        case .retain:
            // Script a transient absent observation followed by an attached final
            // probe. This exercises failed detach without a 12-second poll wait.
            oneAbsentProbe = true
            attached = true
            return false
        }
    }

    func setDetachment(_ value: Detachment) { detachment = value }
    func holdNextAttachmentProbe() { blockAttachmentProbe = true }
    func releaseAttachmentProbe() {
        blockAttachmentProbe = false
        let continuation = blockedAttachmentProbe
        blockedAttachmentProbe = nil
        continuation?.resume()
    }
    func holdNextForce() { blockForce = true }
    func releaseForce() {
        blockForce = false
        let continuation = blockedForce
        blockedForce = nil
        continuation?.resume()
    }
}

@MainActor
private final class LifecycleEnvironment {
    let directory: URL
    let paths: DriveStreamPaths
    let defaults: UserDefaults
    let suiteName: String
    let inspector: FakeMountInspector
    let controller: MountController
    let originalConfig: StreamConfig
    private let eventFile: URL

    init(root: URL, python: String, name: String, behavior: HelperBehavior = HelperBehavior(),
         candidates: [VolumeBackend] = [.nfs]) throws {
        directory = root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        paths = DriveStreamPaths(applicationSupportDirectory: directory.appendingPathComponent("support"),
                                 homeDirectory: directory.appendingPathComponent("home"))
        try paths.prepareFileSystem()
        try Data(Self.helper(python: python).utf8).write(to: paths.rcloneBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.rcloneBinary.path)
        try JSONEncoder().encode(behavior).write(to: paths.applicationSupportDirectory.appendingPathComponent("behavior.json"))
        try Data("[gdrive]\ntype = drive\ntoken = fixture-token-not-valid-for-any-service\n".utf8).write(to: paths.configFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
        eventFile = paths.applicationSupportDirectory.appendingPathComponent("events.jsonl")
        suiteName = "com.drivestream.lifecycle-tests.\(UUID().uuidString)"
        guard let privateDefaults = UserDefaults(suiteName: suiteName) else {
            throw LifecycleFailure(description: "Cannot create private defaults suite")
        }
        defaults = privateDefaults
        var configuration = StreamConfig()
        configuration.volumeName = "Fixture Drive"
        configuration.customMountPath = directory.appendingPathComponent("mount").path
        configuration.mountBackend = .nfs
        configuration.autoMountOnLaunch = false
        configuration.suppressSpotlightIndexing = false
        configuration.showDriveOnDesktop = false
        guard configuration.validationError == nil else {
            throw LifecycleFailure(description: "Fixture mount path must be a valid private /tmp path: \(configuration.validationError ?? "")")
        }
        originalConfig = configuration
        StreamConfigStore.save(configuration, to: defaults)
        // This unique service is deliberately unused: guarded crypt/OAuth tests
        // must fail before touching even this test-only Keychain namespace.
        let keychain = KeychainHelper(service: "com.drivestream.unused-lifecycle.\(UUID().uuidString)")
        inspector = FakeMountInspector(pidFile: paths.applicationSupportDirectory.appendingPathComponent("mount.pid"))
        let dependency = DependencyManager(paths: paths)
        let configService = RcloneConfigService(paths: paths, keychain: keychain)
        controller = MountController(dependencyManager: dependency, configService: configService,
                                     rcClient: RcloneRCClient(), paths: paths, keychain: keychain,
                                     configuration: configuration, initialPins: [], mountInspector: inspector,
                                     defaults: defaults, enableFinderIntegration: false, backendCandidates: candidates)
    }

    func events() -> [HelperEvent] {
        guard let data = try? Data(contentsOf: eventFile) else { return [] }
        return data.split(separator: 10).compactMap { try? JSONDecoder().decode(HelperEvent.self, from: Data($0)) }
    }

    func count(_ kind: String) -> Int { events().filter { $0.kind == kind }.count }
    func pid(_ kind: String) -> Int32? { events().last(where: { $0.kind == kind })?.pid }
    func configContents() throws -> Data { try Data(contentsOf: paths.configFile) }

    func close() async {
        await inspector.setDetachment(.detach)
        await inspector.releaseForce()
        await inspector.releaseAttachmentProbe()
        await controller.shutdownForTermination(allowPendingUploads: true)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Every child only reads this fixture's behavior file and appends its own PID.
    /// authorize/config paths cannot produce a token or write config/Keychain.
    private static func helper(python: String) -> String {
        "#!\(python)\n" + #"""
import base64, json, os, signal, sys, time, traceback
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root = Path(__file__).parent.parent
def fixture_error(kind, value, trace):
    with (root / "fixture-error.txt").open("a") as output:
        traceback.print_exception(kind, value, trace, file=output)
sys.excepthook = fixture_error
behavior = json.loads((root / "behavior.json").read_text())
args = sys.argv[1:]
if len(args) >= 2 and args[0] == "--config":
    config_path = Path(args[1])
    assert config_path == root / "rclone.conf" or (config_path.name == "rclone.conf" and config_path.parent.name.startswith(("DriveStream-oauth-", "DriveStream-drive-list-", "DriveStream-drive-root-"))), "fixture config isolation failed"
    args = args[2:]
command = args[0] if args else ""
kind = (command + "Help") if "--help" in args else command
assert kind in {"version", "mountHelp", "nfsmountHelp", "about", "mount", "nfsmount", "authorize", "config", "backend", "lsf"}, "unexpected fixture command"
def record(value):
    fd = os.open(root / "events.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, (json.dumps({"pid": os.getpid(), "ppid": os.getppid(), "kind": value}) + "\n").encode())
    finally:
        os.close(fd)
record(kind)
def stop(signum, frame):
    record("exit:" + kind)
    raise SystemExit(0)
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)
if behavior.get("delayCommand") == kind or kind in {"authorize", "config"}:
    # Never return an OAuth token, run a browser, mutate config, or reach Keychain.
    while True:
        time.sleep(0.02)
if kind == "version":
    print("rclone v1.70.0")
elif kind.endswith("Help"):
    print("--vfs-cache-mode --vfs-cache-max-size --noappledouble --noapplexattr")
elif kind == "about":
    print(json.dumps({"total": 1000000, "used": 100, "free": 999900}))
elif kind == "backend":
    assert args == ["backend", "drives", "gdrive:"]
    print(json.dumps([{"id":"Shared_A", "name":"Design"}]))
elif kind == "lsf":
    assert args == ["lsf", "gdrive:", "--dirs-only", "--max-depth", "1"]
    assert config_path != root / "rclone.conf"
else:
    assert args[0] in {"mount", "nfsmount"}
    def option(name):
        return args[args.index(name) + 1]
    assert option("--rc-addr") == "127.0.0.1:0", "fixture must bind dynamically"
    assert option("--config") if "--config" in args else True
    cache = Path(option("--cache-dir"))
    namespace = next((line.split("=", 1)[1].strip() for line in config_path.read_text().splitlines() if line.startswith("drivestream_cache_namespace =")), None)
    expected_cache = root / "cache" / "mount-roots" / namespace if namespace else root / "cache"
    assert cache.resolve() == expected_cache.resolve(), "mount must use the cache committed with its root"
    metadata = cache / "vfsMeta"
    authorization = "Basic " + base64.b64encode((option("--rc-user") + ":" + os.environ["RCLONE_RC_PASS"]).encode()).decode()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            record("rc:" + self.path)
            status, payload = 200, {}
            if self.headers.get("Authorization") != authorization:
                status, payload = 401, {"error": "fixture unauthorized"}
            elif self.path == "/core/pid":
                payload = {"pid": os.getpid() + (1 if behavior.get("pidMismatch") else 0)}
            elif self.path == "/vfs/refresh":
                assert body == {"recursive": "true", "_async": True}
                status = behavior.get("refreshStatus", 200)
                payload = {"jobid": 41} if status == 200 else {"error": "fixture refresh failure"}
            elif self.path == "/job/status":
                payload = {"id": 41, "finished": True, "success": True}
            elif self.path == "/core/stats":
                payload = {"bytes": 100, "transferring": [], "fatalError": False, "errors": 0}
                if behavior.get("omitFatalDiagnostic"):
                    payload.pop("fatalError")
            elif self.path == "/vfs/stats":
                assert body == {}
                payload = {"inUse": 0, "diskCache": {"bytesUsed": 0, "files": 0, "uploadsQueued": 0, "uploadsInProgress": 0, "erroredFiles": 0, "outOfSpace": False, "pathMeta": str(metadata.resolve())}}
            elif self.path == "/vfs/queue":
                assert body == {}
                payload = {"queue": []}
                if behavior.get("pendingWrites"):
                    payload = {"queue": [{"id":1, "name":"pending.mov", "size":100, "expiry":1, "tries":0, "delay":1, "uploading":False}]}
                if behavior.get("missingQueue"):
                    payload = {}
            elif self.path == "/core/bwlimit":
                payload = {"rate": body.get("rate", "off")}
            elif self.path == "/operations/about":
                payload = {"total": 1000000, "used": 100, "free": 999900}
            encoded = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            try:
                self.wfile.write(encoded)
            except (BrokenPipeError, ConnectionResetError):
                pass
    metadata.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    (root / "mount.pid").write_text(str(os.getpid()))
    if not behavior.get("suppressAnnouncement"):
        with open(option("--log-file"), "a") as log:
            log.write("2026/01/01 00:00:00 NOTICE: Serving remote control on http://127.0.0.1:" + str(server.server_address[1]) + "/\n")
            log.write("2026/01/01 00:00:01 INFO : PRIVATE_CLOUD_PATH/file.mov token=PRIVATE_TOKEN unstructured_PRIVATE_SECRET http://127.0.0.1:54321/\n")
            log.flush()
            os.fsync(log.fileno())
    if behavior.get("exitBeforeReady"):
        sys.exit(9)
    try:
        server.serve_forever(poll_interval=0.02)
    finally:
        server.server_close()
"""#
    }
}

@main
@MainActor
struct MountLifecycleTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LifecycleFailure(description: message) }
        checks += 1
        print("ok - \(message)")
    }

    private static func waitUntil(_ message: String, timeout: Duration = .seconds(5),
                                  condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LifecycleFailure(description: "Timed out: \(message)")
    }

    private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private static func expectRejected(_ message: String, operation: @MainActor () async throws -> Void) async throws {
        do {
            try await operation()
            throw LifecycleFailure(description: "\(message): unexpectedly succeeded")
        } catch is MountControllerError {
            try expect(true, message)
        }
    }

    private static func cancellationTests(_ make: (String, HelperBehavior, [VolumeBackend]) throws -> LifecycleEnvironment) async throws {
        for command in ["mountHelp", "about", "nfsmountHelp"] {
            let env = try make("cancel-\(command)", HelperBehavior(delayCommand: command), [.nfs])
            let before = try env.configContents()
            let mount = Task { await env.controller.mount() }
            try await waitUntil("fake \(command) child starts") { env.count(command) > 0 }
            guard let helperPID = env.pid(command) else { throw LifecycleFailure(description: "Missing own helper PID") }
            mount.cancel()
            let result = await mount.value
            try expect(!result && env.controller.state.status == .unmounted, "cancel during \(command) does not advertise a mounted volume")
            try expect(env.count("nfsmount") == 0 && env.count("mount") == 0, "cancel during \(command) launches no mount child")
            try expect(!isAlive(helperPID), "cancel during \(command) joins and stops only its own helper")
            let contents = try env.configContents()
            try expect(contents == before, "cancel during \(command) leaves private config unchanged")
            await env.close()
        }
        let env = try make("cancel-after-launch", HelperBehavior(suppressAnnouncement: true), [.nfs])
        let mount = Task { await env.controller.mount() }
        try await waitUntil("private fake mount starts") {
            env.count("nfsmount") == 1 && FileManager.default.fileExists(atPath: env.paths.applicationSupportDirectory.appendingPathComponent("mount.pid").path)
        }
        guard let pid = env.pid("nfsmount") else { throw LifecycleFailure(description: "Missing own mount PID") }
        mount.cancel()
        let result = await mount.value
        let observations = await env.inspector.cancelledObservations
        let forces = await env.inspector.forceCalls
        try expect(!result && !env.controller.hasMountSession, "cancellation after launch cleans the owned session")
        try expect(!isAlive(pid), "cancellation after launch joins the owned mount child")
        try expect(forces > 0 && !observations.contains(true), "abort inspection/detachment runs in joined uncancelled context")
        try expect(env.controller.rcClient.baseURL == nil, "cancelled mount leaves no stale RC endpoint")
        await env.close()

        let readiness = try make("cancel-readiness", HelperBehavior(), [.nfs])
        await readiness.inspector.holdNextAttachmentProbe()
        let readyMount = Task { await readiness.controller.mount() }
        try await waitUntil("readiness observation is suspended") { await readiness.inspector.attachmentProbeIsBlocked }
        readyMount.cancel()
        await readiness.inspector.releaseAttachmentProbe()
        let readyResult = await readyMount.value
        try expect(!readyResult && !readiness.controller.hasMountSession, "cancellation after readiness await cannot publish mounted state")
        try expect(readiness.count("rc:/vfs/refresh") == 0, "cancelled readiness starts no indexing side effect")
        await readiness.close()

        let cancelledUnmount = try make("cancelled-unmount-caller", HelperBehavior(), [.nfs])
        let active = await cancelledUnmount.controller.mount()
        try expect(active, "uncancelled-cleanup fixture starts normally")
        let unmount = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await cancelledUnmount.controller.unmount()
        }
        await unmount.value
        let cancelled = await cancelledUnmount.inspector.cancelledObservations
        try expect(!cancelledUnmount.controller.hasMountSession && !cancelled.contains(true), "pre-cancelled unmount caller still joins uncancelled detachment")
        await cancelledUnmount.close()
    }

    private static func exclusivityTests(_ make: (String, HelperBehavior, [VolumeBackend]) throws -> LifecycleEnvironment) async throws {
        let env = try make("connection-guards", HelperBehavior(), [.nfs])
        let before = try env.configContents()
        let connection = Task { try await env.controller.connectGoogleDrive(useCustomCredentials: false, clientID: "", clientSecret: "") }
        try await waitUntil("inert fake authorization child") { env.count("authorize") == 1 }
        let mounted = await env.controller.mount()
        try expect(!mounted && env.count("nfsmount") == 0, "public mount is excluded while connection task owns lifecycle")
        try await expectRejected("settings are excluded while connection task is active") { try await env.controller.applySettings(env.originalConfig) }
        try await expectRejected("second connection is excluded") { try await env.controller.connectGoogleDrive(useCustomCredentials: false, clientID: "", clientSecret: "") }
        connection.cancel()
        do { try await connection.value; throw LifecycleFailure(description: "Cancelled connection succeeded") }
        catch is CancellationError { try expect(true, "connection cancellation preserves CancellationError") }
        let contents = try env.configContents()
        try expect(contents == before, "inert authorization never supplies tokens or mutates private config")
        await env.close()

        let configEnv = try make("configuration-guards", HelperBehavior(), [.nfs])
        let configuration = Task { try await configEnv.controller.removeGoogleAccount() }
        try await waitUntil("inert fake config helper") { configEnv.count("config") == 1 }
        let configMounted = await configEnv.controller.mount()
        try expect(!configMounted && configEnv.count("nfsmount") == 0, "public mount is excluded while configuration task is suspended")
        try await expectRejected("connection is excluded while configuration task owns lifecycle") {
            try await configEnv.controller.connectGoogleDrive(useCustomCredentials: false, clientID: "", clientSecret: "")
        }
        configuration.cancel()
        do { try await configuration.value; throw LifecycleFailure(description: "Cancelled configuration succeeded") }
        catch is CancellationError { try expect(true, "configuration cancellation stops before Keychain/account deletion") }
        try expect(configEnv.controller.remoteIsConfigured, "cancelled inert config operation preserves account state")
        await configEnv.close()

        let mountingEnv = try make("mounting-guards", HelperBehavior(delayCommand: "about"), [.nfs])
        let mounting = Task { await mountingEnv.controller.mount() }
        try await waitUntil("mount preflight helper") { mountingEnv.count("about") == 1 }
        try await expectRejected("connection is excluded during mount preflight") {
            try await mountingEnv.controller.connectGoogleDrive(useCustomCredentials: false, clientID: "", clientSecret: "")
        }
        try await expectRejected("configuration is excluded during mount preflight") { try await mountingEnv.controller.applySettings(mountingEnv.originalConfig) }
        mounting.cancel()
        _ = await mounting.value
        try expect(mountingEnv.count("authorize") == 0 && mountingEnv.count("config") == 0, "mount/config exclusions invoke no side-effecting helper")
        await mountingEnv.close()
    }

    private static func cleanIdleIssueTests(_ make: (String, HelperBehavior, [VolumeBackend]) throws -> LifecycleEnvironment) async throws {
        let env = try make("omitted-fatal-diagnostic", HelperBehavior(omitFatalDiagnostic: true), [.nfs])
        let mounted = await env.controller.mount()
        try expect(mounted, "controller fixture starts with an omitted optional fatalError")
        let metadata = env.paths.cacheDirectory.appendingPathComponent("vfsMeta", isDirectory: true)
        let finderData = Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31, 0, 0, 0, 0])
        try finderData.write(to: metadata.appendingPathComponent(".DS_Store"))
        try Data([0, 5, 0x16, 7, 0, 2, 0, 0]).write(to: metadata.appendingPathComponent("._sidecar"))
        try Data(#"{"Dirty":false}"#.utf8).write(to: metadata.appendingPathComponent(".real-hidden-file"))
        let safety = await env.controller.refreshWriteSafetyNow()
        try expect(safety.state == .idleObserved && !safety.requiresExitConsent, "fresh controller check accepts clean metadata with Finder sidecars and no fatalError flag")
        await env.controller.unmount()
        try expect(!env.controller.hasMountSession && !env.controller.exitBlockedByWrites, "ordinary idle unmount needs no interruption override")
        try expect(!env.controller.rcloneProcessIsActive, "normal idle unmount joins the fixture helper")
        let retainedFinderData = try Data(contentsOf: metadata.appendingPathComponent(".DS_Store"))
        try expect(retainedFinderData == finderData, "controller inspection does not delete Finder metadata")
        await env.close()
    }

    private static func retainedSessionTests(_ make: (String, HelperBehavior, [VolumeBackend]) throws -> LifecycleEnvironment) async throws {
        let env = try make("retained-session", HelperBehavior(), [.nfs])
        let mounted = await env.controller.mount()
        try expect(mounted, "private fake mount verifies dynamically discovered authenticated PID")
        let before = try env.configContents()
        await env.inspector.setDetachment(.retain)
        // The normal path now refuses to kill a busy helper. Explicit interrupted
        // exit still exercises retention after child exit/failed forced detach.
        await env.controller.unmount(allowPendingUploads: true)
        try expect(env.controller.state.status == .failed && env.controller.hasMountSession, "failed interrupted detach retains attachment-only session after child exit")
        try expect(!env.controller.rcloneProcessIsActive && env.controller.state.volumeStillAttached, "attachment ownership survives child termination")
        try expect(env.controller.mountIssue?.recovery == .retryUnmount, "failed detach offers retry-unmount recovery")
        try expectPrivateLogsStayOnDisk(env, context: "Retained unmount")
        var changed = env.originalConfig
        changed.customMountPath = env.directory.appendingPathComponent("different-mount").path
        changed.volumeName = "Different Fixture"
        try await expectRejected("retained session blocks settings commit") { try await env.controller.applySettings(changed) }
        try await expectRejected("retained session blocks OAuth before inert authorization helper") {
            try await env.controller.connectGoogleDrive(useCustomCredentials: false, clientID: "", clientSecret: "")
        }
        try await expectRejected("retained session blocks crypt before any Keychain operation") {
            try await env.controller.completeOnboarding(volumeName: "Changed", enableEncryption: true,
                                                       cryptPassword: "fixture-not-a-secret", cryptSaltPassword: "",
                                                       autoMount: false, mountBackend: .nfs, mountLocation: .home, cacheMaxSize: "10G")
        }
        try expect(env.controller.config == env.originalConfig && env.controller.mountPath == env.originalConfig.customMountPath,
                   "failed teardown preserves original configuration and live mount path")
        try expect(StreamConfigStore.load(from: env.defaults) == env.originalConfig, "failed teardown never commits changed settings to private defaults")
        let contents = try env.configContents()
        try expect(contents == before && env.count("authorize") == 0 && env.count("config") == 0,
                   "retained-session gates prevent config, OAuth, and encryption writes")
        let refusedQuit = await env.controller.shutdownForTermination()
        try expect(!refusedQuit && env.controller.hasMountSession, "quit is refused while an owned volume remains attached")
        try expect(!env.controller.isBusy, "failed quit leaves retry-unmount controls available")
        await env.inspector.setDetachment(.detach)
        let safeQuit = await env.controller.shutdownForTermination()
        try expect(safeQuit && !env.controller.hasMountSession && env.controller.state.status == .unmounted, "shutdown cleans attachment-only session with no active process")
        try expect(env.controller.mountIssue == nil && env.controller.errorMessage == nil, "successful retry detach clears stale recovery message")
        await env.close()
    }

    private static func fallbackAndCrashTests(_ make: (String, HelperBehavior, [VolumeBackend]) throws -> LifecycleEnvironment) async throws {
        let fallback = try make("fallback-retained", HelperBehavior(pidMismatch: true), [.macFUSE, .nfs])
        await fallback.inspector.setDetachment(.retain)
        let result = await fallback.controller.mount()
        try expect(!result && fallback.controller.hasMountSession, "PID mismatch fails mount and retains failed-detach ownership")
        try expect(fallback.count("mount") == 1 && fallback.count("nfsmount") == 0, "failed cleanup stops fallback before another backend can overwrite process ownership")
        guard let old = fallback.pid("mount") else { throw LifecycleFailure(description: "Missing failed attempt PID") }
        try expect(!isAlive(old), "failed first backend child is joined rather than orphaned")
        await fallback.close()

        let crash = try make("crash-cleanup", HelperBehavior(), [.nfs])
        let mounted = await crash.controller.mount()
        try expect(mounted, "crash fixture starts owned fake mount")
        await crash.inspector.holdNextForce()
        guard let oldPID = crash.pid("nfsmount"), isAlive(oldPID) else { throw LifecycleFailure(description: "No live owned fixture child") }
        // This is the only explicit process signal in the suite; the PID belongs
        // to the currently authenticated, private fixture we just launched.
        guard kill(oldPID, SIGTERM) == 0 else { throw LifecycleFailure(description: "Could not stop own crash fixture") }
        try await waitUntil("tracked crash detach blocks") { await crash.inspector.forceIsBlocked }
        try expect(crash.controller.state.volumeStillAttached && crash.controller.isBusy, "crashed-process attachment and pending cleanup remain visible")
        try expectPrivateLogsStayOnDisk(crash, context: "Unexpected exit")
        var remountFinished = false
        let remount = Task {
            let result = await crash.controller.mount()
            remountFinished = true
            return result
        }
        for _ in 0..<10 { await Task.yield() }
        try expect(!remountFinished && crash.count("nfsmount") == 1, "replacement mount joins old cleanup before launching another process")
        await crash.inspector.releaseForce()
        let replaced = await remount.value
        try expect(replaced && crash.count("nfsmount") == 2, "replacement mount starts only after old cleanup has completed")
        await crash.controller.unmount()
        try expect(!crash.controller.hasMountSession, "old crash cleanup cannot clear replacement ownership before detachment")
        let forceCalls = await crash.inspector.forceCalls
        try expect(forceCalls >= 2, "replacement owned mount receives its own detachment")
        await crash.close()
    }

    private static func refreshTests(_ make: (String, HelperBehavior, [VolumeBackend]) throws -> LifecycleEnvironment) async throws {
        let env = try make("refresh-single-shot", HelperBehavior(refreshStatus: 503), [.nfs])
        let mounted = await env.controller.mount()
        try expect(mounted, "refresh failure does not destroy mounted lifecycle")
        try await waitUntil("single failed refresh finishes") { env.count("rc:/vfs/refresh") == 1 && !env.controller.refreshInProgress }
        try expect(env.count("rc:/vfs/refresh") == 1 && env.count("rc:/job/status") == 0, "HTTP 503 refresh is single-shot and starts no duplicate/status jobs")
        env.controller.forceRefreshDirectoryTree()
        try await waitUntil("explicit second refresh finishes") { env.count("rc:/vfs/refresh") == 2 && !env.controller.refreshInProgress }
        try expect(env.count("rc:/vfs/refresh") == 2, "only explicit user refresh adds a new side-effecting attempt")
        await env.close()
    }

    private static func expectPrivateLogsStayOnDisk(_ env: LifecycleEnvironment, context: String) throws {
        guard let log = env.controller.currentLogURL else { throw LifecycleFailure(description: "Missing private fixture log") }
        let text = try String(contentsOf: log, encoding: .utf8)
        try expect(text.contains("PRIVATE_CLOUD_PATH") && text.contains("PRIVATE_TOKEN"), context + " keeps the full private log on disk")
        let visible = [env.controller.errorMessage, env.controller.state.lastError,
                       env.controller.mountIssue?.title, env.controller.mountIssue?.summary,
                       env.controller.mountIssue?.details].compactMap { $0 }.joined()
        try expect(!visible.contains("PRIVATE_") && !visible.contains("127.0.0.1"), context + " never embeds private log text in UI state")
        try expect(env.controller.mountIssue?.details.contains("Open Logs") == true, context + " offers on-disk log access")
    }

    private static func driveRootTests(_ make: (String, HelperBehavior, [VolumeBackend]) throws -> LifecycleEnvironment) async throws {
        let startup = try make("private-startup-failure", HelperBehavior(exitBeforeReady: true), [.nfs])
        let ready = await startup.controller.mount()
        try expect(!ready, "fixture exit before readiness fails closed")
        try expectPrivateLogsStayOnDisk(startup, context: "Startup failure")
        await startup.close()

        let env = try make("root-switch", HelperBehavior(), [.nfs])
        let mounted = await env.controller.mount()
        try expect(mounted, "root-switch fixture starts mounted")
        let original = try env.configContents()
        let drives = try await env.controller.availableSharedDrives()
        try expect(drives.first?.id == "Shared_A" && env.controller.isMounted, "shared-drive discovery leaves mounted volume running")
        let afterDiscovery = try env.configContents()
        try expect(afterDiscovery == original, "discovery cannot mutate the live mount config")
        PinnedPathStore.save(["old-root-pin.mov"], to: env.defaults)
        var draft = env.controller.config
        draft.sharedDriveID = "Shared_A"
        try await env.controller.applySettings(draft)
        try expect(env.controller.isMounted && env.controller.config.sharedDriveID == "Shared_A", "saving selected root verifies, commits and remounts")
        try expect(env.count("lsf") == 1 && env.count("nfsmount") == 2, "root verification precedes exactly one replacement mount")
        try expect(PinnedPathStore.load(from: env.defaults).isEmpty, "root-relative pins do not cross to another drive")
        let profile = env.controller.configService.profile(for: "gdrive")
        try expect(profile?.sharedDriveID == "Shared_A" && profile?.cacheNamespace != nil, "private config owns both drive and cache identity")
        try expect(StreamConfigStore.load(from: env.defaults).sharedDriveID == "Shared_A", "successful root is reflected in saved Settings")
        await env.controller.unmount()

        // Simulate stale UserDefaults after a crash between config commit and UI save.
        let reboot = MountController(dependencyManager: env.controller.dependencyManager,
            configService: env.controller.configService, rcClient: RcloneRCClient(), paths: env.paths,
            configuration: env.originalConfig, initialPins: ["old-root-pin.mov"], mountInspector: env.inspector,
            defaults: env.defaults, enableFinderIntegration: false, backendCandidates: [.nfs])
        try expect(reboot.config.sharedDriveID == "Shared_A" && reboot.pinnedPaths.isEmpty, "restart trusts private root config rather than stale defaults or pins")
        let rebootMounted = await reboot.mount()
        _ = await reboot.shutdownForTermination(allowPendingUploads: true)
        try expect(rebootMounted, "restart mounts using atomically persisted cache namespace")
        await env.close()

        for (name, behavior) in [("pending", HelperBehavior(pendingWrites: true)), ("unknown", HelperBehavior(missingQueue: true))] {
            let blocked = try make("root-" + name, behavior, [.nfs])
            let mounted = await blocked.controller.mount()
            try expect(mounted, name + " write fixture mounts")
            let before = try blocked.configContents()
            var changed = blocked.controller.config
            changed.sharedDriveID = "Shared_A"
            try await expectRejected(name + " writes block a mount-root change") { try await blocked.controller.applySettings(changed) }
            try expect(blocked.controller.hasMountSession && blocked.count("lsf") == 0, "blocked root keeps old helper and never verifies a replacement")
            let after = try blocked.configContents()
            try expect(after == before && blocked.controller.config.sharedDriveID.isEmpty, "blocked root leaves private config and settings untouched")
            await blocked.close()
        }

        let dirty = try make("root-dormant-dirty", HelperBehavior(), [.nfs])
        let metadata = dirty.paths.cacheDirectory.appendingPathComponent("vfsMeta", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        try ServiceFileSafety.createPrivateFile(metadata.appendingPathComponent("pending.mov"), data: Data(#"{"Dirty":true}"#.utf8))
        var changed = dirty.controller.config
        changed.sharedDriveID = "Shared_A"
        let before = try dirty.configContents()
        try await expectRejected("dormant dirty cache blocks root change even with no helper") { try await dirty.controller.applySettings(changed) }
        let after = try dirty.configContents()
        try expect(after == before && dirty.count("lsf") == 0, "dormant dirty cache is preserved without changing destination")
        await dirty.close()
    }

    private static func pureRegressionTests() throws {
        let genuine = "2026/01/01 00:00:00 NOTICE: Serving remote control on http://127.0.0.1:12345/"
        try expect(RCServerEndpoint.parseAnnouncement(genuine)?.port == 12345, "startup parser accepts real NOTICE dynamic endpoint")
        try expect(RCServerEndpoint.parseAnnouncement("2026/01/01 00:00:00 INFO : file NOTICE: Serving remote control on http://127.0.0.1:12345/") == nil,
                   "INFO filename cannot spoof RC startup announcement")
        try expect(RCServerEndpoint.parseAnnouncement(genuine.replacingOccurrences(of: "127.0.0.1", with: "example.com")) == nil,
                   "startup parser never accepts non-loopback URL")
        try expect(MountPresence.unknown.mayBeMounted && !MountPresence.unmounted.mayBeMounted, "unknown mount inspection conservatively retains ownership")
        try expect(DriveStreamIssue.mountFailure(description: "macFUSE: network is unreachable").title == "The drive could not connect", "network cause wins over filesystem backend label")
        try expect(DriveStreamIssue.mountFailure(description: "macFUSE: HTTP 429 rate limit").title == "Google Drive is limiting requests", "rate-limit cause wins over filesystem backend label")
        try expect(DriveStreamIssue.mountFailure(description: MountControllerError.encryptionNotConfigured.localizedDescription).recovery == .openSetup,
                   "missing crypt setup routes recovery to Setup Assistant")
        let escaped = #"{"password":"prefix\"PRIVATE_SUFFIX","access_token":"TOKEN_FIXTURE"}"#
        let redacted = DiagnosticRedactor.redact(escaped + " --rc-pass=CLI_FIXTURE --client-secret='SECRET FIXTURE'")
        try expect(!redacted.contains("PRIVATE_SUFFIX") && !redacted.contains("TOKEN_FIXTURE") && !redacted.contains("CLI_FIXTURE") && !redacted.contains("SECRET FIXTURE"),
                   "diagnostic redaction covers escaped JSON quotes and equals/quoted CLI secrets")
    }

    static func main() async {
        var environments: [LifecycleEnvironment] = []
        do {
            guard CommandLine.arguments.count == 3 else {
                throw LifecycleFailure(description: "usage: MountLifecycleTests <private-/tmp-root> <absolute-python>")
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let python = CommandLine.arguments[2]
            guard root.path.hasPrefix("/tmp/drivestream-lifecycle."), python.hasPrefix("/"),
                  !python.contains("\n"), !python.contains(" ") else {
                throw LifecycleFailure(description: "Refusing unsafe fixture paths")
            }
            let make = { (name: String, behavior: HelperBehavior, candidates: [VolumeBackend]) in
                let environment = try LifecycleEnvironment(root: root, python: python, name: name, behavior: behavior, candidates: candidates)
                environments.append(environment)
                return environment
            }
            try pureRegressionTests()
            try await cancellationTests(make)
            try await exclusivityTests(make)
            try await cleanIdleIssueTests(make)
            try await retainedSessionTests(make)
            try await fallbackAndCrashTests(make)
            try await refreshTests(make)
            try await driveRootTests(make)
            for environment in environments { await environment.close() }
            print("All \(checks) MountController lifecycle checks passed (Swift 6, isolated fixtures, no real mounts/auth/Keychain writes).")
        } catch {
            for environment in environments { await environment.close() }
            for environment in environments {
                let diagnostics = environment.paths.applicationSupportDirectory.appendingPathComponent("fixture-error.txt")
                if let text = try? String(contentsOf: diagnostics, encoding: .utf8) {
                    FileHandle.standardError.write(Data(text.utf8))
                }
            }
            FileHandle.standardError.write(Data("FAIL: lifecycle regression: \(error)\n".utf8))
            exit(1)
        }
    }
}

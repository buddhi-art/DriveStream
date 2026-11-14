#!/usr/bin/env python3
"""Check the retained repository structure and important runtime/build guardrails."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
ORIGINAL_FILES = [
    ".github/workflows/build-release.yml", "project.yml", "README.md",
    "Sources/Info.plist", "Sources/DriveStream.entitlements",
    "Sources/App/DriveStreamApp.swift", "Sources/App/AppDelegate.swift",
    "Sources/App/FinderServicesProvider.swift", "Sources/Models/StreamConfig.swift",
    "Sources/Models/RCStatsModels.swift", "Sources/Models/MountState.swift",
    "Sources/Services/DependencyManager.swift", "Sources/Services/KeychainHelper.swift",
    "Sources/Services/RcloneConfigService.swift", "Sources/Services/RcloneRCClient.swift",
    "Sources/Services/MountController.swift", "Sources/Views/MenuBarPopoverView.swift",
    "Sources/Views/TransferRowView.swift", "Sources/Views/SettingsView.swift",
    "Sources/Views/OnboardingView.swift",
]
MODERNIZED_FILES = [
    "Sources/Services/FinderIntegrationService.swift", "Sources/Services/MountTable.swift",
    "Sources/Services/MountProbe.swift", "Sources/Services/VolumePresenter.swift",
    "Sources/Services/VolumeIconFlag.swift", "Sources/Services/PinEngine.swift",
    "Sources/Services/CommandRunner.swift", "Sources/Services/FileDownloader.swift",
    "Sources/Services/ServiceFileSafety.swift", "Sources/Services/DependencyArchiveSafety.swift",
    "Sources/Services/RCServerEndpoint.swift", "Sources/Services/MountInspection.swift",
    "Sources/Services/MountArgumentsBuilder.swift",
    "Sources/Services/TelemetryService.swift", "Sources/Models/DriveStreamIssue.swift",
    "Sources/Models/GoogleOAuthCredentials.swift", "Sources/Views/DriveStreamIssueView.swift",
    "Scripts/ServiceSafetyTests.swift", "Scripts/run-service-tests.sh",
    "Scripts/MountLifecycleTests.swift", "Scripts/run-lifecycle-tests.sh",
    ".github/dependabot.yml",
    "Sources/Models/AppEvents.swift", "Sources/Models/PerformancePolicy.swift", "Sources/Models/UploadSafety.swift",
    "Sources/Services/ProcessLaunchEnvironment.swift", "Sources/Services/RcloneObscuration.swift",
    "Sources/Services/RcloneCredentialTransport.swift", "Sources/Services/RclonePrivateConfig.swift",
    "Sources/Services/PinFileIO.swift", "Sources/Services/PinTraversal.swift",
    "Sources/Services/WriteSafetyReader.swift", "Sources/Services/WriteRiskStore.swift",
    "Sources/Services/DirtyCacheInspection.swift", "Sources/Services/DeviceLifecycleMonitor.swift",
    "Sources/Services/LoginItemManager.swift", "Sources/Views/SidebarHelpView.swift", "Sources/Views/PendingWritesView.swift",
    "Tests/DriveStreamCoreTests.swift", "Scripts/SecurityRegressionTests.swift", "Scripts/run-security-tests.sh",
    "Scripts/PinEngineTests.swift", "Scripts/run-pin-tests.sh", "Scripts/RecoveryRegressionTests.swift", "Scripts/run-recovery-tests.sh",
    "Sources/Services/CacheMetadataReader.swift", "Sources/Services/RcloneProcessSupervisor.swift",
    "Sources/Services/MountTelemetryCoordinator.swift",
    "Sources/Views/SettingsGeneralTab.swift", "Sources/Views/SettingsPerformanceTab.swift",
    "Sources/Views/SettingsAccountTab.swift", "Sources/Views/SettingsAdvancedTab.swift", "Sources/Views/SettingsComponents.swift",
    "Sources/Views/OnboardingWelcomeStep.swift", "Sources/Views/OnboardingAccountStep.swift",
    "Sources/Views/OnboardingEncryptionStep.swift", "Sources/Views/OnboardingFinishStep.swift", "Sources/Views/OnboardingComponents.swift",
    "Scripts/UploadSafetyRegressionTests.swift", "Scripts/run-upload-safety-tests.sh",
    "Scripts/MonitorKeychainTests.swift", "Scripts/run-monitor-keychain-tests.sh",
    "Scripts/TelemetryCoordinatorTests.swift", "Scripts/run-telemetry-tests.sh",
]
errors = []
for name in ORIGINAL_FILES + MODERNIZED_FILES:
    path = ROOT / name
    if not path.is_file() or path.stat().st_size == 0:
        errors.append("Missing or empty required file: " + name)


def text(name):
    path = ROOT / name
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def require(condition, description):
    if not condition:
        errors.append(description)


controller = text("Sources/Services/MountController.swift")
rc = text("Sources/Services/RcloneRCClient.swift")
config = text("Sources/Models/StreamConfig.swift")
project = text("project.yml")
workflow = text(".github/workflows/build-release.yml")
onboarding = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "Sources/Views").glob("Onboarding*.swift"))
supervisor = text("Sources/Services/RcloneProcessSupervisor.swift")

require('SWIFT_VERSION: "6.0"' in project, "Project must use Swift 6 language mode.")
require("SWIFT_STRICT_CONCURRENCY: complete" in project, "Complete strict concurrency must remain enabled.")
require("SWIFT_TREAT_WARNINGS_AS_ERRORS: YES" in project, "Swift warnings must fail the application build.")
require(not re.search(r"\bPipe\s*\(", controller + supervisor), "Mount process must not attach an unread Pipe.")
for name in ("standardInput", "standardOutput", "standardError"):
    require(f"process.{name} = FileHandle.nullDevice" in supervisor, f"rclone {name} must use nullDevice.")
arguments = text("Sources/Services/MountArgumentsBuilder.swift")
require('"--log-file", logURL.path' in arguments, "rclone must write through --log-file.")
for flag in ("--noappledouble", "--noapplexattr"):
    require(flag in config, "Missing canonical flag: " + flag)
require("supportedAppleMetadataFlags" in arguments, "Apple flags must be capability-gated.")

for path in sorted((ROOT / "Sources").rglob("*.swift")):
    source = path.read_text(encoding="utf-8")
    require(not re.search(r"--no-(?:appledouble|applexattr)\b", source), f"Invalid Apple flag in {path.relative_to(ROOT)}")
    require(not re.search(r"\.waitUntilExit\s*\(", source), f"Blocking process wait in {path.relative_to(ROOT)}")
    require("@unchecked Sendable" not in source, f"Unchecked Sendable conformance in {path.relative_to(ROOT)}")
    require(not re.search(r"\bNSLock\s*\(", source), f"Manual NSLock state in {path.relative_to(ROOT)}")

require("final class RcloneRCClient: Sendable" in rc and "OSAllocatedUnfairLock" in rc, "RC connection state must be checked Sendable and lock-owned.")
require('let recursive = "true"' in rc and "let _async = true" in rc, "Refresh must use the typed asynchronous request.")
require("timeoutIntervalForResource = 120" in rc, "RC resource timeout must stay generous.")
require("refreshAttempt" not in controller, "The controller must not automatically replay a refresh side effect.")
require("RCServerEndpoint.listenAddress" in arguments, "Mounting must use the dynamic loopback endpoint.")
require('listenAddress = "127.0.0.1:0"' in text("Sources/Services/RCServerEndpoint.swift"), "rclone must own the OS-assigned port from bind time.")
require("5572" not in controller and "5572" not in rc, "Production RC transport must not depend on port 5572.")
require("processID()" in controller, "Readiness must authenticate and verify the launched process identity.")
require("isTransient" in text("Sources/Services/TelemetryService.swift"), "Telemetry retry must classify transient errors.")
require("telemetryWarning" in controller and "telemetryIsStale" in controller, "Failed telemetry must visibly retain its last good readings.")
require('DisclosureGroup("Show Details"' in text("Sources/Views/DriveStreamIssueView.swift"), "Mount diagnostics must remain behind Show Details.")
require("DiagnosticRedactor.redact" in text("Sources/Models/DriveStreamIssue.swift"), "Diagnostic detail must be redacted.")
require("IOStorageFamily.kext/Contents/Resources/External.icns" in text("Sources/Services/VolumePresenter.swift"), "Native volume icon fallback must remain available.")

for label in ("Client ID", "Client Secret", "Personal OAuth client", "rclone default", "4K video scrubbing", "Finder browsing", "rclone crypt", "macOS Keychain"):
    require(label in onboarding, "Onboarding feature missing: " + label)
service = text("Sources/Services/RcloneConfigService.swift")
for account in ("cryptPassword", "cryptSaltPassword", "googleClientSecret"):
    require("KeychainAccountName." + account in service, "Keychain persistence missing: " + account)
require("mutationInProgress" in service and "@MainActor" in service, "Configuration writers must be isolated across suspension points.")
require("actualHash == expectedHash" in text("Sources/Services/DependencyManager.swift"), "The official rclone archive must be checksum-verified before execution.")
require("needsExitAssessment" in text("Sources/App/AppDelegate.swift"), "Quit must handle retained mounts and persisted write warnings.")
require("performAbortMountAttempt" in controller and "Task.detached" in controller, "Cancellation-safe mount cleanup must remain joined.")

require("ENABLE_HARDENED_RUNTIME: YES" in project, "App Hardened Runtime must remain enabled.")
require("ENABLE_HARDENED_RUNTIME=YES" in workflow and "--options runtime" in workflow, "Final CI signing must retain runtime protection.")
require("DriveStreamTests:" in project and "bundle.unit-test" in project, "Hostless native test target missing.")
require("ProcessLaunchEnvironment.make" in supervisor, "Long-lived helper environment must be allowlisted.")
require("ProcessInfo.processInfo.environment" not in controller + supervisor, "Mount helper must not inherit arbitrary environment.")
require('"--rc-pass"' not in arguments, "RC password must not be exposed in argv.")
require("RcloneObscuration.obscure" in service, "Crypt keys must be obscured in process rather than argv.")
require("uploadQueue()" in rc and "core/bwlimit" in rc, "Write queue and bandwidth controls missing.")
require("unmountIfUnused" in controller, "Ordinary detach must ask macOS before terminating a healthy helper.")
require("maximumConcurrentFiles" in text("Sources/Services/PinEngine.swift"), "Bounded cache warming missing.")
require("willSleepNotification" in text("Sources/Services/DeviceLifecycleMonitor.swift"), "Sleep/wake observation missing.")
require("openMountFolderForSidebar" in text("Sources/Views/SidebarHelpView.swift"), "Supported persistent Finder shortcut guidance missing.")

for action in re.findall(r"^\s*uses:\s*([^\s#]+)", workflow, flags=re.MULTILINE):
    require(re.fullmatch(r"[^@]+@[a-f0-9]{40}", action) is not None, "CI action must be pinned to an immutable commit: " + action)
require("DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer" in workflow, "CI must select its supported stable Swift 6 Xcode explicitly.")
require('"ARCHS=arm64 x86_64"' in workflow, "Release must include Apple Silicon and Intel slices.")
require("SWIFT_STRICT_CONCURRENCY=complete" in workflow, "Release must preserve strict concurrency checking.")

if errors:
    for error in errors:
        print("ERROR: " + error, file=sys.stderr)
    raise SystemExit(1)
print(f"All {len(ORIGINAL_FILES)} original required files are non-empty; {len(MODERNIZED_FILES)} modernization files are present.")
print("Swift 6, RC security, mount lifecycle, telemetry, onboarding, icon, and release guardrails passed.")

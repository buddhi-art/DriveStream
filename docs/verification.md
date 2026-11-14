# DriveStream 1.2.1 — issue-fix verification

Verified locally on **6 November 2026** with Apple Swift **6.4.2**, the real macOS **26.5 SDK**, and a macOS **14.0** deployment target. The [1.2.0 record](<verification-1.2.0.md>) is preserved separately rather than being reused as proof for this patch.

## Changes verified

- Optional missing/false `fatalError` no longer turns a complete idle queue into an error or masks out-of-space/cache-error states.
- Read-only cache scanning distinguishes verified Finder binary sidecars from real hidden remote metadata. Descriptor-relative no-follow traversal includes hidden entries, including valid JSON with sidecar-like names.
- Metadata is read in 4 KiB increments, not limited to a 4 KiB whole record; a 256 KiB per-file bound, entry/depth/time limits and fail-closed behavior remain.
- Lifecycle monitoring creates a fresh network monitor on restart and ignores callbacks from stopped sessions.
- Keychain presence queries are metadata-only and noninteractive; existing login-Keychain routing/ACL behavior is preserved. **No automatic biometric migration is claimed.**
- Process mechanics and display telemetry were extracted from the controller; settings/onboarding keep parent-owned state while rendering focused components.

The full rationale, including corrected claims in the input report, is in [the resolved issue review](<../issues.md>).

## Executed checks

| Suite | Result |
| --- | ---: |
| Model smoke | 105 assertions |
| RC integration | 88 assertions |
| Service safety | 89 checks |
| Controller lifecycle | 71 assertions |
| Credential security | 95 offline checks |
| Recovery ordering | 57 assertions |
| Idle/cache metadata issue regressions | 28 assertions |
| Monitor/Keychain query regressions | 108 checks |
| Display telemetry coordinator | 13 assertions |
| Pin engine | 15 grouped PASS cases |

That is **654 individually counted assertions/checks plus 15 grouped pin cases**. The integrated suites and the dedicated coordinator suite passed against identical final application source. RC transport and monitor/Keychain suites also passed under **Thread Sanitizer**.

The full controller tests exercise an omitted optional fatal flag plus Finder sidecars, confirm ordinary idle unmount without an interrupted-exit override, and retain the existing held-write/unknown-state protections. Monitor/Keychain tests use injected fake boundaries: they do not access the user's Keychain, present authentication UI, change network settings or subscribe a real app to workspace events.

The actual disposable **local-remote rclone NFS** acceptance passed its **10 direct assertions plus 4 bounded transfer/recovery checks**, including read/write, dirty-writer refusal, simulated offline/sleep/wake events, bandwidth change without remount, and normal detach. This is not real Google Drive authorization or a guarantee about every NFS/driver workload. The [earlier documented NFS limitations](<verification-1.2.0.md#an-investigated-nfs-limitation>) remain relevant.

## Build, UI and artifacts

- Entire real application compiled and linked with Swift 6, complete concurrency, warnings-as-errors, `-O` and whole-module optimization for **arm64** and **x86_64**.
- No substitute State wrapper, macro shim, custom unchecked Sendable exemption or full-Xcode execution claim.
- XcodeGen **2.46.0** generation, actionlint, plist/entitlement checks and repository guardrails passed.
- Native snapshots of extracted performance settings and account/encryption steps were rendered and inspected. No real sign-in, secret retrieval or login-item registration was invoked.
- Locally assembled **1.2.1** app contains both slices and was explicitly signed with **Hardened Runtime** plus an **ad-hoc** signature; signature verification reports the runtime flag.
- ZIP integrity, DMG integrity and the versioned SHA-256 manifest passed. Source bytes were compared to the compiler snapshot before packaging.

The versioned local assets are named:

```text
DriveStream-1.2.1.dmg
DriveStream-1.2.1-macOS.zip
SHA256SUMS-1.2.1.txt
```

Older 1.2.0 assets are not modified by these source changes. Use the new version or build the updated source.

## Not claimed as executed here

- Real Google Desktop OAuth/Drive/crypt account acceptance.
- macFUSE/FSKit or FUSE-T runtime testing.
- Physical sleep/Wi-Fi/VPN transition and login-item approval testing.
- Intel/Rosetta or macOS 14 hardware execution (the slices and deployment target were compiled).
- A completed GitHub Actions or native XCTest run; full Xcode/XCTest is unavailable on this CLT-only host.
- A signed-app data-protection-Keychain migration or biometric unlock workflow.
- Developer ID signing, notarization, durable cloud-sync guarantees or eviction-proof offline pinning.

**The new app is locally compiled, ad-hoc signed with Hardened Runtime, and not notarized.** Follow [the README](<../README.md>) and [security policy](<../SECURITY.md>) before trusting important files.

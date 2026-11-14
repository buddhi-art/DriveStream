# DriveStream 1.2.0 — executed verification record

Verified on **6 November 2026** on an **8 GB Apple M1 MacBook Air**. This record separates executed checks from configured CI and untested Google/driver/hardware coverage.

## Build and signing

- Apple Swift **6.4.2**, real installed macOS **26.5 SDK**, deployment target **macOS 14.0**.
- Swift 6 language mode, complete strict concurrency and warnings-as-errors.
- Entire real application compiled and linked with `-O -whole-module-optimization` for **arm64** and **x86_64**, without a State shim or custom unchecked-Sendable exemption.
- Universal app contains both slices. The packaged source snapshot was compared with the working-tree source before assembly.
- Project/build/CI settings enable Hardened Runtime; final ad-hoc signing explicitly includes `--options runtime`.
- Signature verification passed. CodeDirectory inspection reports `flags=0x10002(adhoc,runtime)`.
- ZIP test, DMG integrity test and versioned SHA-256 checksums passed for the local 1.2.0 assets.
- XcodeGen 2.46.0 clean-tree generation passed, including the new hostless native test target; actionlint and plist checks passed.

**The local bundle is a CLT-compiled/assembled build, not a claimed GitHub Actions/Xcode build.** The [release workflow](<../.github/workflows/build-release.yml>) is configured to build the generated project and run the hostless native XCTest target with full Xcode 26.3 on `macos-15`. No local XCTest execution is claimed: this host has CLT but not a full Xcode/XCTest module installation.

## Final standard regression run

| Suite | Executed result | Main coverage |
| --- | ---: | --- |
| Model smoke | 105 assertions | Parsers, mount profile, OAuth resolution, redaction and bounded retry/recovery |
| RC integration | 88 assertions | Authentication, dynamic endpoints, PID, typed bodies, redirects, cancellation and concurrent connection changes |
| Service safety | 89 checks | Private I/O, timeout/cancellation, atomic replacement, exact checksums and unsafe archives |
| Controller lifecycle | 66 assertions | Startup cancellation, exclusivity, retained sessions, fallback, crash cleanup, single-shot refresh and failed-quit recovery |
| Credential security | 95 offline checks | Allowlisted child environment, no crypt/OAuth secret argv, exact UTF-8 obscuration, private candidates and rollback |
| Recovery ordering | 57 assertions | Delayed checks, stale/old responses, unavailable endpoints, dirty metadata, busy normal-unmount refusal, persistent risks and wake intent |
| Pin engine | 15 PASS groups | Bounded readers, no-follow traversal, failures, overlaps, progress and joined cancellation |

The six individually counted suites total **500 assertions/checks**, plus **15 grouped pin tests**. The final complete `make test` run exited **0**. Pin groups are not misrepresented as a count of every internal assertion.

The final RC suite also passed under **Thread Sanitizer**. The credential implementation passed **31 additional interoperability checks** with a checksum-verified official rclone v1.75.2 binary: the combined optional run reported **126 checks**. Those checks used private local fixtures, never a real Google sign-in or the user's Keychain.

Fixtures use private paths, a private UserDefaults suite, unused/test credential stores and fake inspectors. Hostless tests do not instantiate the real application environment or change Finder preferences/register login items.

## Actual isolated local NFS mount

An explicit live test used the real current controller, mount builder and official rclone **v1.75.2**, against a **disposable local alias remote**, not Google Drive. All **10 direct assertions and 4 bounded transfer/recovery checks** passed:

1. Actual NFS mount reaches controller readiness.
2. Authenticated PID and assigned RC port verify.
3. Volume is registered with macOS and present in the browsable mounted-volume list.
4. A real cached NFS read matches the 1 MiB fixture.
5. A closed write reaches the local remote.
6. Queue plus read-only dirty metadata eventually show idle.
7. Held modified writer is not silently approved by an empty queue.
8. Ordinary unmount preserves the helper while that write/open state remains.
9. Explicit client synchronize/close lets the held write complete remotely.
10. Simulated offline/sleep events preserve the actual attachment.
11. Wake health returns to the same helper PID.
12. Cached read remains valid afterward.
13. Bandwidth-only settings apply without restarting the helper.
14. Final non-forced detach leaves no test volume; fixture cleanup verifies the canonical private path.

Network/sleep events in this test were **injected lifecycle events**, not physical lid closure or changes to the user's network. Finder preferences and Keychain were not changed. Browsable macOS volume registration is not proof that every user's Finder sidebar preferences display the item; the supported sidebar guide explains the one-time Favorites/visibility setup.

## An investigated NFS limitation

An earlier live fixture's held write remained dirty after a long power/activity gap. The cache contained the complete bytes, but the remote object had not been acknowledged. The guard correctly retained the cache; this was not treated as a successful upload.

Independent private raw NFSv3 tests with official rclone showed ordinary WRITE, safe-save-like rename and SETATTR/COMMIT fixtures finishing after about five seconds. Reading the **same dirty file** repeatedly reset its write-back expiry; it completed only after those reads stopped. Close QuickLook/readers/previews as well as writers while waiting for changed data to upload.

The original post-gap indefinite stall was **not conclusively attributed to one cause**. Explicit client synchronization improved the fresh live acceptance test, but is not cloud durability: the inspected NFS implementation returns FILE_SYNC without forcing cloud upload and its COMMIT implementation is a no-op. NFS remains an experimental fallback, not APFS semantics. No dirty flag is cleared manually and no live cache chunks are deleted as a workaround.

Short custom NFS timeout/retry overrides were removed; the remaining soft-mount choice uses the platform's retry policy and can still return I/O errors. Prefer a verified FUSE setup or a separately verified local project copy for write-sensitive work where those semantics are unacceptable.

## Measured Swift performance

The [performance report](<performance.md>) and [raw evidence](<benchmarks/pin-warm-apfs-raw.jsonl>) retain scope and bias controls. On the warmed-APFS medium fixture, unchanged legacy versus two-reader Swift medians were **51.60 → 22.22 ms**, with median process peak RSS **264.14 → 14.14 MiB**. These are local cache-warming measurements, not Google/Finder/network throughput.

Reusable POSIX buffers, bounded workers and throttled progress achieved the improvement in Swift. No unavoidable measured Swift limitation justified adding Rust.

## Remaining external acceptance

Not claimed as executed here:

- Real personal Google Desktop OAuth consent and authenticated Google Drive transfers/crypt migration.
- macFUSE/FSKit or FUSE-T mounting and application compatibility.
- Physical sleep/Wi-Fi/VPN transitions and login-item approval on an installed production account.
- Running the Intel slice on Intel hardware/Rosetta or runtime testing on macOS 14 hardware.
- A completed GitHub Actions/native XCTest run or Developer ID notarization.
- A durable cloud-sync guarantee, protected offline-pin lease or live synchronous cache purge.

The app is **ad-hoc signed with Hardened Runtime, not notarized**. Obscured keys remain recoverable in the private config, helper environment credentials remain same-user-visible, and the VFS cache can contain plaintext. Use the [README](<../README.md>) and [security policy](<../SECURITY.md>) before working with important data.

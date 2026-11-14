# Security policy

## Supported versions and verification status

Security fixes target the latest maintained source/release. DriveStream is a local, open-source desktop app, not a hosted service. The current project configuration is **1.2.1**; do not infer a published stable Release, successful CI run or completed real-Google sign-in from implemented code or configured tests. See the [verification record](<docs/verification.md>) for executed checks and the [performance report](<docs/performance.md>) for the narrowly scoped benchmark.

Default release signing is **ad-hoc with Hardened Runtime**, not Developer ID signing or notarization. Hardened Runtime does not identify an Apple-verified publisher, sandbox the app, or protect user-owned secrets from every same-user process.

## Reporting a vulnerability

Please report security issues privately through this repository's GitHub **Security Advisories/private vulnerability reporting** feature when enabled. Do not open a public issue for an unpatched vulnerability. If private reporting is unavailable, contact the maintainer privately before sharing a proof of concept or sensitive logs publicly.

Include:

- A description of the issue and its impact.
- DriveStream/rclone versions, macOS version, architecture and selected backend.
- Minimal reproduction steps or a proof of concept using disposable data.
- Relevant logs with credentials, account information, file contents and private paths removed.

Reports are reviewed on a best-effort basis. Allow time for a fix before public disclosure. Never send live OAuth tokens, Client Secrets, crypt keys, private config/cache files, Keychain exports or signing identities in a public report.

## Threat model

DriveStream:

- Downloads and executes an official checksum-verified rclone helper.
- Starts an authenticated RC server on a kernel-assigned `127.0.0.1` port.
- Mounts a Drive/crypt remote using an available FUSE backend or experimental local NFS. The inspected official rclone v1.75.2 NFS implementation is **NFSv3**, not NFSv4.
- Stores OAuth tokens/client settings and reversible crypt password copies in a private config; stores secret/password copies in the login Keychain.
- Stages downloaded and modified plaintext in a policy-managed local VFS cache, including decrypted data when cloud-side crypt is enabled.
- Accepts selected Finder paths through Services, observes network/sleep/wake state, and supports user-directed login registration.
- Uses fresh queue/stat evidence and bounded read-only private-cache inspection to warn before ordinary exit.

### In scope

- RC authentication bypass, endpoint exposure beyond loopback or stale-session/PID confusion.
- OAuth, client-secret, crypt-key or RC-password disclosure caused by DriveStream.
- Command/argument/environment injection and unsafe secret transport.
- Finder Services reading outside the selected/mounted volume, including symlink escapes.
- Traversal or unsafe ownership handling in config, staging, helper archives, mount paths, cache observation, icons and logs.
- Integrity failures in official helper/optional installer verification.
- Destructive shutdown/cache handling that bypasses ordinary pending-write protections or affects an unrelated mount/process.
- Local privilege escalation caused by DriveStream and secrets accidentally published in diagnostics, preferences or the repository.

### Out of scope and residual boundaries

- Vulnerabilities in rclone, Google Drive, macOS, macFUSE or FUSE-T themselves; report these upstream. DriveStream integration errors can still be in scope.
- A compromised Google account, compromised local macOS account, or physical access to an unlocked Mac.
- Treating same-user processes as a reliably isolated security principal. They can read/modify user-owned config/cache files and inspect helper environments. Loopback Basic auth, file permissions and Keychain copies do not eliminate this threat.
- Gatekeeper warnings caused by ad-hoc signing and absent notarization.
- Cloud/network availability, quota limits, account policies, and denial of service from an exhausted local working set. Cache size is a policy limit, not an instantaneous hard ceiling; open/dirty files and cleaner timing can exceed it.

## Security design

### Process launch and credentials

- [ProcessLaunchEnvironment](<Sources/Services/ProcessLaunchEnvironment.swift>) supplies a fixed trusted PATH, actual user home/private temporary directory and stable UTF-8 locale. It forwards only the six supported HTTP(S)/no-proxy spellings and approved explicit credential overrides. Arbitrary inherited `DYLD_*`, `RCLONE_*`, API keys, cloud credentials, forged HOME/TMPDIR and locale values are not forwarded. `ALL_PROXY`, PAC and arbitrary certificate-path overrides are deliberately unsupported.
- The mounted RC server binds to `127.0.0.1:0`; a random per-session 256-bit password is mandatory. Exact startup discovery and authenticated `core/pid` verification bind it to the launched child. Redirects, missing credentials and stale generations fail closed; `--rc-no-auth` is not used.
- OAuth client options and RC passwords use **deliberate allowlisted environment overrides**, not secret positional arguments. Same-user debuggers/process inspection can still read those environments, and helper children may inherit them. Environment transport is not a vault or privilege boundary.
- [RcloneObscuration](<Sources/Services/RcloneObscuration.swift>) implements the compatible CommonCrypto AES-CTR obscuration primitive in Swift, with a random IV and the upstream public fixed key. It preserves UTF-8 bytes, whitespace and line breaks without a line-oriented/argv fallback. Neither plaintext nor obscured crypt keys need to be supplied as helper arguments.
- **Obscuration is reversible, not config encryption.** Anyone able to read the private config can recover crypt keys. The login-Keychain copy does not imply a Touch ID/user-presence gate, and the local VFS cache can contain decrypted data.

### Keychain access policy

The existing file-based/login Keychain uses macOS ACLs and lock-state controls. Standard generic-password items are not freely readable by every same-user process merely because they lack a biometric attribute. [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) distinguishes this implementation from the data-protection Keychain used for biometric access policies.

The helper preserves existing storage routing and item access controls. Presence checks are status-only (`kSecReturnData=false`) with `kSecUseAuthenticationUISkip`, so UI rendering never falls back to an interactive secret read. Cancellation, authentication refusal, lock/entitlement failures and corruption are surfaced rather than treated as a reason to delete/recreate an item or weaken its policy.

No automatic biometric migration is performed. A future optional user-presence mode requires explicit migration consent, data-protection routing on every operation, signed-app validation and rollback/recovery. It also requires addressing recoverable configuration-file key copies; protecting only the Keychain copy is not end-to-end local key protection.

### Private storage and publication

- Support/cache/log directories are tightened to `0700`; config and secret staging files are created as `0600`. The enclosing private support directory is the helper's access boundary. FileVault is recommended for disk-at-rest protection, independently of cloud-side crypt.
- OAuth/crypt operations verify a private candidate config **before publishing Keychain/config changes**, preserve exact prior config/credential snapshots, and reject an intervening active-config change. Crypt candidate verification is a shallow listing, not proof that every old object can decrypt.
- Publication uses private staging and atomic config replacement, with best-effort restoration after partial credential/config writes. **Keychain plus filesystem publication is not a distributed atomic transaction.** Rollback can fail and a process/system crash can interrupt it. Preserve independent exact recovery keys and private config backups; a failed operation is not unconditional proof that every old credential was restored.
- The official rclone archive is HTTPS-downloaded and verified against its exact versioned checksum entry before extraction/execution. ZIP traversal, duplicate entries, symlinks and unsupported layouts are rejected; only the expected executable is extracted. Atomic same-directory replacement preserves a previously working helper when candidate verification fails.
- Optional macFUSE installer downloads use the selected official release filename/checksum and do not overwrite existing user Downloads files. Detection of a driver bundle does not prove approval or force an FSKit backend; follow upstream installation/security guidance.

### File I/O, lifecycle and pending writes

- [PinTraversal](<Sources/Services/PinTraversal.swift>) uses descriptor-relative no-follow opens, including intermediate components. Symlink roots are rejected and symlink descendants skipped; ordinary hidden regular files remain eligible. Overlaps are deduplicated and traversal/read failures do not create new complete markers for affected roots. Markers are successful read snapshots, **not eviction-proof offline leases**.
- Bounded Swift workers own their file descriptors and reusable buffers. Progress snapshots are serialized/throttled, and cancellation joins work before the pin call returns. An already-blocked kernel filesystem read cannot safely/reliably be interrupted by cross-thread close; cancellation can await the backend response rather than abandon an orphan worker.
- Swift 6 language mode, complete strict concurrency and warnings-as-errors are configured. Mutable shared state uses actors or native allocated locks with checked Sendable application types; config mutations have explicit reentrancy guards.
- Lifecycle tasks propagate cancellation and retain failed owned attachments. Ordinary shutdown checks fresh write evidence and asks for a normal unmount before stopping a running owned helper. Unrelated/pre-existing mounts are not force-detached to make startup succeed. Credential changes/helper replacement are blocked while a retained session remains.
- [WriteSafetyReader](<Sources/Services/WriteSafetyReader.swift>) combines authenticated queue/core/VFS observations with [DirtyCacheInspection](<Sources/Services/DirtyCacheInspection.swift>). The latter reads **version-dependent internal metadata**, not a stable public inventory/purge API. It scans only inside the private cache, with entry/time/per-file-size budgets; incomplete, missing, malformed, symlink/escape or unsupported evidence is unknown and does not approve ordinary exit.
- Optional absent diagnostics do not override complete queue/cache evidence or mask explicit out-of-space/fatal states. Cache metadata is read incrementally in 4 KiB chunks with a 256 KiB per-record bound. Only verified Finder sidecar formats are ignored; hidden remote metadata remains included and malformed/unreadable records fail closed.
- A clean-looking upload queue is not enough: a modified open file may not yet be queued. Close writers and verify important remote files independently. A satisfied network path, empty stats, completed Finder copy or detached filesystem does not prove cloud durability.
- **Quit Anyway** is an explicit interrupted-exit override. Cache data is retained, but required uploads may remain incomplete; this is not an upload-flush or recovery guarantee. The private [write-risk ledger](<Sources/Services/WriteRiskStore.swift>) is a best-effort cross-restart warning, not an authoritative cloud-acknowledgement journal.
- Neither eviction controls nor dirty-cache inspection purge live sparse cache data/metadata. `vfs/forget` invalidates directory metadata; rclone's own policy governs reclamation. Never delete required pending cache files behind the helper.
- Read-only telemetry uses bounded transient retries. Lost refresh/forget responses are not automatically replayed as side effects. Sleep/network loss preserves healthy cached attachments; wake health recovery is not a guaranteed reconnection or time-to-flush contract.

### System integration and distribution

- Launch at login uses supported `SMAppService` registration only after a user toggle; initialization reads status. Finder's persistent shortcut guide asks the user to drag a folder into Favorites, not to modify private sidebar databases or pretend a detached folder is a Locations volume.
- The app is not sandboxed and existing Finder preference controls affect the user's Finder globally. It does not automatically restore all prior preferences on uninstall. No Finder Sync/status-badge or biometric-gated crypt workflow is implied.
- The 1.2 project/release commands enable Hardened Runtime, and final signing includes `--options runtime`. Default signing is still ad-hoc and **not notarized**; verify artifact provenance and signature integrity.
- CI actions are pinned to immutable commits; credential/pin/CLI suites and hostless core XCTest are configured as build gates. Configuration is not evidence that CI or the native target ran successfully. Require the actual reviewed run before publishing.
- UI diagnostics redact known secret patterns and bound private helper output. Full logs, filenames and unfamiliar formats can still be sensitive; review before sharing. No analytics backend, remote telemetry or third-party crash-reporting service is included.

## Hardening recommendations

- Use a personal Google Desktop OAuth client, authorize only trusted builds, and revoke access when no longer needed.
- Keep backups and independent exact crypt recovery keys; protect private config/cache with account security and FileVault.
- Leave free SSD headroom for pending writes and use an appropriate cache/resource/bandwidth policy.
- Close writers and verify important files in Google Drive before ordinary Unmount/Quit; prefer Keep Running when status is unknown.
- Preserve cache/config after an interrupted exit until required local writes are recovered. Do not treat the recovery ledger or pin markers as backup proof.
- Verify release checksums and signatures. An intact ad-hoc Hardened Runtime signature is not a notarized publisher identity.
- Test the selected backend with disposable files; experimental NFS avoids a third-party driver but does not remove network-filesystem limitations.

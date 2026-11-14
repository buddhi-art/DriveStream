# Copilot guidance and security review

## Summary

DriveStream has a strong security-oriented design: helper environments are
allowlisted, RC endpoints are loopback-only with generation checks, private
files use restrictive permissions, archive extraction is bounded, and the
regression suites cover credential transport, path traversal, and configuration
rollback. No critical issue was confirmed in the reviewed security-sensitive
surface. The main concern is that an authenticated RC error response can be
copied into user-visible error text without redaction; the remaining findings
are fail-closed/reliability gaps and helper-integrity hardening opportunities.

## Issues

### MAJOR RC error bodies can disclose sensitive data

- **File**: `Sources/Services/RcloneRCClient.swift`
- **Line**: 326
- **Problem**: Non-2xx RC responses are decoded from the response body and, when
  no structured error is available, the first 800 bytes are retained as
  `RcloneRCError.http.message`. Its `errorDescription` returns that message,
  and callers such as mount eviction include `error.localizedDescription` in
  UI-facing failure text. A helper or local process that returns an error body
  containing a token, path, or other private data can therefore bypass the
  redaction used by `DriveStreamIssue`.
- **Suggestion**: Do not expose arbitrary RC response bodies in
  `LocalizedError`. Map known status/cause values to fixed messages and keep
  raw response data in a private, bounded log after applying the same
  redaction policy used for diagnostics. Add a regression test that injects a
  token-bearing RC error response and asserts it cannot reach the surfaced
  error string.

### MAJOR Existing helper binaries are not revalidated against provenance

- **File**: `Sources/Services/DependencyManager.swift`
- **Line**: 269
- **Problem**: On later launches, an executable already present in the private
  `bin` directory is accepted after behavioral checks (`version` and
  `mount --help`). The exact official archive checksum is verified during
  download, but no persisted digest or signature is checked before reusing the
  existing binary. A replacement in that directory could receive the private
  config path and allowlisted OAuth/RC environment values.
- **Suggestion**: Persist the verified archive/binary digest (or a verified
  publisher signature) alongside the installation metadata and check it before
  every reuse. If verification fails, quarantine the candidate and reinstall
  from the versioned checksum-verified archive. Treat the digest record as
  private and update it only after successful installation.

### MINOR Finder preference failures are silently converted into success

- **File**: `Sources/Services/FinderIntegrationService.swift`
- **Line**: 14
- **Problem**: `writeDefault` discards every command failure, while
  `applyFirstRunSetupIfNeeded` sets `firstRunKey` unconditionally afterward.
  A permissions, process, or OS-version failure can leave network-store
  suppression and Finder preferences unapplied permanently, with no retry or
  user-visible warning.
- **Suggestion**: Return a success/failure result from `writeDefault`, set the
  first-run marker only when all required writes succeed, and surface a
  non-sensitive warning when optional Finder polish cannot be applied.

### MINOR Quarantine-clearing failure is ignored during helper installation

- **File**: `Sources/Services/DependencyManager.swift`
- **Line**: 441
- **Problem**: Failure of `/usr/bin/xattr -c` is ignored before the candidate
  helper is verified and installed. This can leave quarantine metadata or other
  extended attributes on the executable while the app reports a successful
  installation, producing inconsistent launch behavior and obscuring whether
  the intended post-download cleanup completed.
- **Suggestion**: Either make the cleanup step an explicit required check with a
  typed error, or document it as optional and verify/report the resulting
  attribute state before publishing the candidate. Do not silently discard the
  command result.

### MINOR Remote deletion is not protected by the same transaction pattern

- **File**: `Sources/Services/RcloneConfigService.swift`
- **Line**: 380
- **Problem**: `removeRemote` invokes rclone's live `config delete` directly. Unlike
  OAuth, crypt, and shared-drive updates, it does not snapshot the config,
  verify the resulting file, or restore the previous bytes if the helper
  partially fails. A failed deletion can leave configuration state inconsistent
  without the recovery guarantees documented for other configuration mutations.
- **Suggestion**: Use the existing candidate-config workflow: snapshot the live
  bytes, apply the deletion to a private candidate, validate the candidate,
  compare the live file before publication, atomically replace it, and restore
  the snapshot on any post-publication failure.

## Positive controls verified

- `ProcessLaunchEnvironment` forwards only the documented proxy spellings and
  explicit credential overrides.
- `RcloneRCClient` rejects non-loopback endpoints and disables redirects.
- `ServiceFileSafety`, `PinTraversal`, and `DirtyCacheInspection` use
  no-follow and descriptor-relative operations for sensitive filesystem paths.
- Downloaded rclone archives are version-pinned, checksum-verified, and checked
  for ZIP traversal, duplicate entries, symlinks, and oversized expansion.
- OAuth/crypt publication uses private candidates and preserves prior
  configuration and credential snapshots.
- The repository explicitly documents residual same-user, FileVault, cache,
  notarization, and cloud-durability boundaries in `SECURITY.md`.

## Project-specific Copilot guidance

- Treat OAuth tokens, client secrets, crypt passwords, RC passwords, private
  config/cache files, logs, filenames, and local paths as sensitive.
- Never add credentials to command arguments, inherited environment variables,
  UI errors, telemetry, or public diagnostics. Use the existing allowlisted
  environment and private-file helpers.
- Preserve fail-closed behavior for unknown cache evidence, stale mount
  generations, path traversal, archive ambiguity, and configuration races.
- Use descriptor-relative `O_NOFOLLOW` operations for Finder/cache traversal and
  validate mount ownership before unmounting.
- Keep configuration changes candidate-based, byte-preserving where possible,
  atomically published, and recoverable after partial Keychain/config failure.
- Do not infer a successful release, CI run, notarization, or real Google sign-in
  from configuration alone; consult `docs/verification.md`.
- Relevant offline checks include:
  `bash Scripts/run-security-tests.sh`,
  `bash Scripts/run-review-regressions.sh`, and
  `bash Scripts/validate-project.sh`.

## Verdict

**Changes Requested**

The RC error-body disclosure should be fixed before treating the security review
as approved. The helper provenance, Finder preference, quarantine cleanup, and
transactional deletion items should be addressed or explicitly accepted with
tests and documented residual-risk decisions.

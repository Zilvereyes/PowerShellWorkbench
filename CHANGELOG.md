# Changelog

## 0.8.0 - 2026-09-07

- Add a bounded, read-only text-integrity diagnostic for PowerShell sources. It reports encoding, byte hash, normalized-text hash, line endings, byte-only versus semantic drift, and invalid or unstable input without writing, starting processes, networking, or transporting data.
- Add a hash-bound project assessment sidecar and portal view. It exposes source commit, host binding, sanitization state, exact per-target failed gates, verified evidence hashes, readiness (`PASS`, `WAITING`, `BLOCKED`, or `NOT_RUN`), and the next permitted action; missing or drifted state blocks rather than passing.

## 0.7.13 - 2026-09-07

- Preserve an explicit context profile choice instead of overriding it with boundary or capability heuristics.
- Restrict heuristic context classification to the supplied start path by default; broader ancestor classification now requires opt-in and never selects a drive root heuristically.
- Probe PowerShell runtime architecture from the runtime itself rather than relying only on executable-path names.
- Make portable project-profile paths explicit about configured versus resolved paths, existence, containment, and external-path authorization.
- Preserve the generated `main` component in missing-profile portal previews, display configured-to-resolved working paths, and write generated JSON as UTF-8 without BOM on both supported PowerShell hosts.
- Correct stale skill guidance for test discovery, the mandatory automatic-variable scan path, and the existing project-profile portal.

## 0.7.12

- See the merge commit `e0e1f5405854a4cb626dcf8d1db0fc838219f24e` for the released source state.

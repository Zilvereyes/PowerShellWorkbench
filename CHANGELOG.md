# Changelog

## 0.8.1 - Unreleased

- Make installed-plugin governance testing explicitly skip only when the complete repository governance context is unavailable; partial governance state still fails. Portable marketplace contracts now exercise this installed-artifact behavior.
- Add optional fail-closed text policies for encoding, line endings, and mixed line endings while preserving 0.8.0's observation-only defaults.
- Add Project Assessment schema 1.1 with non-Git SHA-256 source identities, profile hash binding, whole-project evidence containment, target applicability, freshness, and safe/offline/live/postcondition proof states. Add a preview-default assessment generator that never marks a target PASS.
- Add a read-only Doctor overview for context, runtime, profile, assessment, text policy, explicit installation evidence, duplicate-identical channels, and the next safe action.
- Make Doctor's default runtime state explicitly `SKIPPED`; its child-PowerShell runtime probe is opt-in.
- Add optional `num_ctx` request binding to the bounded Ollama adapter. Requested context is recorded separately from unknown effective context; no runtime observation is invented.
- Add portable quality-plan fields to new project profiles and correct the product display name to `PowerShell Workbench`.

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

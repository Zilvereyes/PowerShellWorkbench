# Changelog

## 0.7.13 - Unreleased

- Preserve an explicit context profile choice instead of overriding it with boundary or capability heuristics.
- Restrict heuristic context classification to the supplied start path by default; broader ancestor classification now requires opt-in and never selects a drive root heuristically.
- Probe PowerShell runtime architecture from the runtime itself rather than relying only on executable-path names.
- Make portable project-profile paths explicit about configured versus resolved paths, existence, containment, and external-path authorization.
- Preserve the generated `main` component in missing-profile portal previews, display configured-to-resolved working paths, and write generated JSON as UTF-8 without BOM on both supported PowerShell hosts.
- Correct stale skill guidance for test discovery, the mandatory automatic-variable scan path, and the existing project-profile portal.

## 0.7.12

- See the merge commit `e0e1f5405854a4cb626dcf8d1db0fc838219f24e` for the released source state.

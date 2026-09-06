---
name: microsoft-dism-docs
description: Research DISM.exe, DISM PowerShell cmdlets, Windows image servicing, WIM, VHD, FFU, WinPE, and ADK behavior from official Microsoft documentation.
---

# Microsoft DISM Docs

Use the `microsoft-dism` domain in `../../assets/documentation-source-catalog.json` as the discovery boundary.
Validate that catalog first with `../../scripts/Test-PowerShellWorkbenchDocumentationCatalog.ps1` and an independently
recorded catalog SHA-256. A stale, drifted, malformed, or unknown catalog is not trusted.

- Resolve the target host, image type, online or offline state, Windows release, ADK or WinPE context, and tool surface.
- Distinguish `dism.exe` syntax from the DISM PowerShell module; do not assume every option has an identical cmdlet mapping.
- Prefer the version-selected technical reference and cmdlet reference. Cite the exact page and documented applicability.
- Treat servicing, mounting, image repair, capture, apply, commit, and discard as potentially mutating operations.
- Documentation research and command composition do not authorize execution, elevation, mounting, servicing, or file writes.
- When documentation and an observed host differ, report the conflict and retain the raw version and command evidence.

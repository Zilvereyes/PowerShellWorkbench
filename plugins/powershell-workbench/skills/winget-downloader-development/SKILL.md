---
name: winget-downloader-development
description: Modernize WingetDownloader with explicit exports, help, tests, structured status, cache integrity, safe paths, and recovery handoff compatibility.
---

# WingetDownloader Development

Resolve the active source with `../../scripts/Resolve-PowerShellWorkbenchContext.ps1 -RequestedProfile WingetDownloader`. Treat `WingetDownloader.psm1`
and `WingetDownloader.psd1` as authoritative. Use `WingetDownloader_Chat_Knowledge_Base` only to explain history, compare proposals, or recover rationale
after checking live source. If discovery fails, ask for the current project root instead of falling back to another laptop's path.

Prioritize work in this order unless the user specifies otherwise:

1. Replace wildcard exports with a stable, explicit public surface.
2. Add comment-based help and an `about_WingetDownloader` topic.
3. Add Pester coverage for import, package discovery, download construction, status recovery, cache reuse, path sanitization, checksums, and the offline guard.
4. Separate public commands, private helpers, and experimental dependency, rollback, or servicing behavior without breaking callers.
5. Preserve structured status/error files, hexadecimal WinGet failure codes, SHA-256 verification, safe paths, and the non-executing recovery-media handoff.

Keep Windows PowerShell 5.1 and PowerShell 7 compatibility. Never execute installers, delete caches, perform servicing, or run quality gates without an explicit request.

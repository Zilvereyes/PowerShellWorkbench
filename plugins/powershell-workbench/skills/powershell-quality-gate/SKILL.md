---
name: powershell-quality-gate
description: Run requested PowerShell parser, import, PSScriptAnalyzer, Pester, MegaLinter, or Codex Security checks and report unavailable gates without silently passing them.
---

# PowerShell Quality Gate

Use this skill only when the user asks to validate, lint, test, scan, or check PowerShell work.
For a mixed project, first use the technology map from `Resolve-PowerShellWorkbenchContext.ps1` and run only the native checks relevant to files in scope. PowerShell gates remain mandatory only for PowerShell changes.

Run only the requested tier, expanding to later tiers only when the user asks:

1. Parse targeted files in both `powershell.exe` and `pwsh`.
2. Run `../../scripts/Test-PowerShellWorkbenchAutomaticVariables.ps1 -NoThrow` before executable servicing or recovery work. It uses the PowerShell parser directly and avoids shell-quoted `-Command` wrappers.
3. For an explicitly requested native operation, use `../../scripts/Invoke-PowerShellWorkbenchNativeCommand.ps1` for visible operator blocks, streamed output, redacted JSON/timeline reporting, and an optional post-check. Use `-AnalyzeOnly` for report-only preflight; it never starts the target process.
4. Import the targeted module in both runtimes when import is safe and requested.
5. Run PSScriptAnalyzer with repository settings or the packaged configuration template.
6. Run the smallest relevant Pester scope, then broader tests only when requested.
7. Use MegaLinter for repository-wide lint orchestration when requested.
8. Use the matching Codex Security scan workflow only when a security review is requested.
9. For non-PowerShell components, use their repository-declared formatter, linter, test, schema, or build command; do not invent a new toolchain merely because MegaLinter supports it.

If a runtime, module, Docker, MegaLinter, or security capability is unavailable, mark that gate `SKIPPED` with the missing prerequisite. Never report an unavailable gate as passed. Preserve unrelated files and never disable rules or add broad exclusions without approval.

Linear tracking is optional. Create or modify an issue only after an explicit user request and an exact preview of what will be written.

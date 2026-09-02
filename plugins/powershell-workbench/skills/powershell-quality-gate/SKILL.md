---
name: powershell-quality-gate
description: Run requested PowerShell parser, import, PSScriptAnalyzer, Pester, MegaLinter, or Codex Security checks and report unavailable gates without silently passing them.
---

# PowerShell Quality Gate

Use this skill only when the user asks to validate, lint, test, scan, or check PowerShell work.
For a mixed project, first use the technology map from `Resolve-PowerShellWorkbenchContext.ps1` and run only the native checks relevant to files in scope. PowerShell gates remain mandatory only for PowerShell changes.

Run only the requested tier, expanding to later tiers only when the user asks:

1. Parse targeted files in both `powershell.exe` and `pwsh`.
2. Import the targeted module in both runtimes when import is safe and requested.
3. Run PSScriptAnalyzer with repository settings or the packaged configuration template.
4. Run the smallest relevant Pester scope, then broader tests only when requested.
5. Use MegaLinter for repository-wide lint orchestration when requested.
6. Use the matching Codex Security scan workflow only when a security review is requested.
7. For non-PowerShell components, use their repository-declared formatter, linter, test, schema, or build command; do not invent a new toolchain merely because MegaLinter supports it.

If a runtime, module, Docker, MegaLinter, or security capability is unavailable, mark that gate `SKIPPED` with the missing prerequisite. Never report an unavailable gate as passed. Preserve unrelated files and never disable rules or add broad exclusions without approval.

Linear tracking is optional. Create or modify an issue only after an explicit user request and an exact preview of what will be written.

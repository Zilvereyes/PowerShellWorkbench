---
name: powershell-refactor
description: Refactor or optimize PowerShell scripts and modules while preserving behavior, exported commands, safety boundaries, and Windows PowerShell 5.1 plus PowerShell 7 compatibility.
---

# PowerShell Refactor

Use this skill for implementation changes, modularization, duplication removal, performance work, command-surface cleanup, or maintainability improvements in PowerShell.

1. Identify the live source, public commands, callers, tests, and documented safety boundaries before editing.
2. Select `Generic`, `RecoveryToolkit`, or `WingetDownloader` conventions from `../powershell-scaffold/references/project-profiles.md`.
3. If the repository mixes languages or build systems, route cross-stack decisions through `powershell-centered-project-development` and preserve each component's native conventions.
4. Preserve parameter names, output shapes, exit behavior, `SupportsShouldProcess`, and explicit safety checks unless the user requests an interface change.
5. Prefer small public functions, private helpers, explicit module exports, structured results, deterministic path handling, and comment-based help.
6. Keep syntax and runtime behavior compatible with both Windows PowerShell 5.1 and PowerShell 7.
7. Do not elevate, service images, execute installers, delete caches, or write recovery media without an explicit request.
8. Do not run lint, tests, MegaLinter, or security scans unless requested. When requested, route to `powershell-quality-gate`.

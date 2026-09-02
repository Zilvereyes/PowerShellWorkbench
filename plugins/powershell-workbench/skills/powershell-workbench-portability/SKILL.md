---
name: powershell-workbench-portability
description: Package PowerShell Workbench for another project, workstation, laptop, local marketplace, or Git-backed Codex marketplace without embedding machine-specific project paths.
---

# PowerShell Workbench Portability

Use this skill when the user wants to reuse, move, share, install, or update PowerShell Workbench on another project or computer.

1. Keep project discovery portable. Use `../../scripts/Resolve-PowerShellWorkbenchContext.ps1`; never copy a source path from one workstation into required plugin behavior.
2. For a folder, archive, or future Git repository, run `../../scripts/New-PortablePowerShellWorkbenchMarketplace.ps1 -Destination <path>`. This creates `.agents/plugins/marketplace.json` and `plugins/powershell-workbench` under one portable root.
3. Validate the packaged plugin before distribution.
4. A second computer can add a local package with `codex plugin marketplace add <marketplace-root>`, or a Git-backed package with `codex plugin marketplace add owner/repository --ref <ref>`.
5. GitHub access is required only to create, push, or update the remote repository. Local packaging and local installation require no GitHub credentials.
6. Do not install third-party GitHub Marketplace Actions by default. Prefer direct PowerShell, Pester, and PSScriptAnalyzer commands plus pinned official actions; add a third-party action only after a specific review and explicit request.

When moving to another machine, optionally create `%USERPROFILE%\.config\powershell-workbench\projects.json` for projects that cannot be found by walking up from the active workspace.

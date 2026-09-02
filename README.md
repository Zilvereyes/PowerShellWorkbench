# PowerShell Workbench

PowerShell Workbench is a portable Codex plugin for PowerShell-centered and mixed-language projects. It supports Windows PowerShell 5.1 and PowerShell 7, with reusable scaffolding, refactoring guidance, project discovery, optional quality gates, and focused workflows for RecoveryToolkit and WingetDownloader.

## Install from GitHub

On each laptop, authenticate Git for GitHub access and run:

```powershell
codex plugin marketplace add Zilvereyes/PowerShellWorkbench --ref main
codex plugin add powershell-workbench@powershell-workbench
```

Start a new Codex task after installation so the skills are loaded.

## Update

```powershell
codex plugin marketplace upgrade powershell-workbench
codex plugin remove powershell-workbench@powershell-workbench
codex plugin add powershell-workbench@powershell-workbench
```

Then start a new Codex task.

## Included workflows

- Scaffold scripts, advanced functions, modules, manifests, tests, contracts, documentation, lint configuration, and CI files.
- Refactor PowerShell while preserving behavior, compatibility, exports, and safety boundaries.
- Discover mixed-language project context without embedding workstation-specific paths.
- Apply RecoveryToolkit and WingetDownloader conventions when those projects are detected.
- Run parser, PSScriptAnalyzer, Pester, MegaLinter, and Codex Security gates only when explicitly requested.
- Package the plugin for another local marketplace, workstation, or Git-backed marketplace.

## Repository layout

```text
.agents/plugins/marketplace.json
plugins/powershell-workbench/
```

The marketplace manifest points to `./plugins/powershell-workbench`. Project paths are discovered at runtime and are not stored in this repository.

## Safety

The plugin does not perform elevation, image servicing, installer execution, cache deletion, recovery-media writes, or remote backlog writes unless explicitly requested.


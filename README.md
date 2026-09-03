# PowerShell Workbench

PowerShell Workbench is a portable Codex plugin for PowerShell-centered and mixed-language projects. It supports Windows PowerShell 5.1 and PowerShell 7, with reusable scaffolding, refactoring guidance, project discovery, optional quality gates, and focused workflows for RecoveryToolkit and WingetDownloader.

## Windows prerequisite

`codex` must be available as a terminal command. Codex Desktop may contain an application-private binary without exposing it on `PATH`. Follow the [current official instructions](https://developers.openai.com/codex/cli). Avoid piping downloaded scripts directly into `Invoke-Expression`; authenticate installation artifacts before execution.

Open a new PowerShell window and verify:

```powershell
codex --version
Get-Command codex
```

Adding `%APPDATA%\npm` to `PATH` does not install npm or Codex.

## Install from GitHub

On each laptop, authenticate Git for GitHub access and select a reviewed immutable release tag or commit:

```powershell
$PluginRef = '<reviewed-release-tag-or-full-commit>'
codex plugin marketplace add Zilvereyes/PowerShellWorkbench --ref $PluginRef
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
- Make precise, low-churn edits to compact or generated code when normal patch context is fragile.
- Discover mixed-language project context without embedding workstation-specific paths.
- Apply RecoveryToolkit and WingetDownloader conventions when those projects are detected.
- Run parser, PSScriptAnalyzer, Pester, MegaLinter, and Codex Security gates only when explicitly requested.
- Package the plugin for another local marketplace, workstation, or Git-backed marketplace.
- Diagnose PowerShell, Codex, Git, Node/npm, Docker, winget, and PATH before workstation setup.
- Inventory several explicitly scoped projects or a project-profile registry with bounded discovery.
- Build safe PowerShell orchestration for local models, agent CLIs, capability registries, evaluations, checkpoints, and provider switching.
- Resume phase-journaled provider transactions without repeating a verified switch, evaluate named runtime/certification gate groups, and generate deterministic local-only JSON/Markdown handoffs.
- Route PowerShell-centered Lua/WoW addon, game-data, VS Code extension, Node, .NET, native, and web tooling without collapsing native contracts.

## Bounded Codex JSONL evidence

PowerShell Workbench includes a PowerShell 7 runner for `codex exec --json` and a separate PowerShell 5.1/7 evidence validator. The runner closes stdin, streams stdout and stderr into byte-bounded files, terminates the process tree on timeout or output overflow, and records executable plus artifact hashes.

Validation fails closed on artifact or executable substitution, process/tool failures, orphaned or duplicate tool events, missing success state,
excessive or malformed JSONL, incomplete turn lifecycle, insufficient tool calls, unexpected final text, and optionally retries. Model, provider,
endpoint, and context remain explicitly unverified caller declarations unless a future provider supplies trusted attestation.

```powershell
$capture = & '<plugin-root>\scripts\Invoke-PowerShellWorkbenchCodexJson.ps1' `
    -Prompt 'Use one read-only tool, then return EXACT_OK.' `
    -ModelId 'model-name' `
    -ModelDigest 'verified-model-digest' `
    -ProviderId 'local-provider' `
    -Endpoint 'http://127.0.0.1:11434' `
    -EffectiveContext 131072

& '<plugin-root>\scripts\Test-PowerShellWorkbenchCodexEvidence.ps1' `
    -MetadataPath $capture.MetadataPath `
    -ExpectedMetadataSha256 '<independently-recorded-metadata-sha256>' `
    -ExpectedExecutableSha256 '<independently-pinned-codex-executable-sha256>' `
    -AcceptUnverifiedRuntimeDeclarations `
    -MinimumSuccessfulToolCalls 1 `
    -ExpectedFinalText 'EXACT_OK' `
    -RequireExactFinalText
```

The runner requires PowerShell 7 for reliable argument handling, asynchronous cancellation, and process-tree termination.
The validator, fixtures, contract tests, and provider-switch transaction template support Windows PowerShell 5.1 and PowerShell 7.

## Useful diagnostics

```powershell
& '<plugin-root>\scripts\Get-PowerShellWorkbenchEnvironment.ps1'

& '<plugin-root>\scripts\Get-PowerShellWorkbenchProjectInventory.ps1' `
    -Root 'C:\ProjectOne','C:\ProjectTwo'
```

## Repository layout

```text
.agents/plugins/marketplace.json
plugins/powershell-workbench/
```

The marketplace manifest points to `./plugins/powershell-workbench`. Project paths are discovered at runtime and are not stored in this repository.

## Safety

The plugin does not perform elevation, image servicing, installer execution, cache deletion, recovery-media writes, or remote backlog writes unless explicitly requested.

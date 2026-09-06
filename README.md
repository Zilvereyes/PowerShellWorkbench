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
- Validate patch bytes, envelopes, target uniqueness, invocation mode, and host adapter read-only before applying a rejected patch.
- Discover mixed-language project context without embedding workstation-specific paths.
- Apply RecoveryToolkit and WingetDownloader conventions when those projects are detected.
- Run parser, PSScriptAnalyzer, Pester, MegaLinter, and Codex Security gates only when explicitly requested.
- Package the plugin for another local marketplace, workstation, or Git-backed marketplace.
- Diagnose PowerShell, Codex, Git, Node/npm, Docker, winget, and PATH before workstation setup.
- Validate explicit Git/personal plugin source-cache pairs, expected versions, duplicate roots, and optional hash-bound catalog freshness without writing to the installation.
- Preview a freshness-bounded, generator- and policy-hash-bound local-model catalog schema migration without writing, launching Codex, or inventing schema 1.1 transport evidence from a legacy manifest.
- Inventory several explicitly scoped projects or a project-profile registry with bounded discovery.
- Build safe PowerShell orchestration for local models, agent CLIs, capability registries, evaluations, checkpoints, and provider switching.
- Prepare or explicitly invoke one byte- and time-bounded loopback Ollama `/api/chat` request, preserve hash-bound raw request/response evidence, and record tool calls without executing them.
- Compare two or more frozen Ollama evidence captures against one hash-bound task, keep quality separate from performance, and rank only valid passing candidates without retries, model calls, writes, or transport.
- Resolve a read-only `DECLARED` / `FOUND` / `VALIDATED` product dashboard by binding health-checked distribution trees to hash-bound release provenance.
- Turn one validated `read_file_slice` tool call into a deterministic proposal, require a separate hash-bound approval, execute only a bounded read, and resolve missing evidence as `UNKNOWN` or contradictory evidence as `CONFLICT`.
- Resume phase-journaled provider transactions without repeating a verified switch, evaluate named runtime/certification gate groups, and generate deterministic local-only JSON/Markdown handoffs.
- Recognize an interruption after a hash-verified provider profile write, bind resume evidence to loopback endpoint, wire API, local-model catalog and canonical owned state, and return `ManagedCommitRequired` with `DesktopLifecycleInvoked=False` instead of switching the provider again.
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

## Bounded direct Ollama evidence

`Invoke-PowerShellWorkbenchOllamaChat.ps1` is read-only and network-free unless `-Execute` is supplied. Execution is restricted to an exact credential-free literal loopback-IP HTTP `/api/chat` endpoint. It disables streaming and thinking, bounds prompt/request/response bytes, timeout and output tokens, and never executes returned tool calls.

`Test-PowerShellWorkbenchOllamaEvidence.ps1` separately validates single-read byte snapshots from the hash-bound capture. A model digest remains an unverified caller declaration unless the validator is explicitly told to accept that limitation.

`-EnableReadFileSliceProposal` adds one fixed Ollama function schema to the request. It does not execute the returned call.
`New-PowerShellWorkbenchReadOnlyToolProposal.ps1` converts a validated response into a deterministic proposal;
`New-PowerShellWorkbenchReadOnlyToolApproval.ps1` previews unless `-Approve` is explicit; and
`Invoke-PowerShellWorkbenchReadOnlyTool.ps1` previews unless `-Execute` is explicit. Proposal, approval, target and observation
are independently hash-bound, output writes require a separate scoped evidence root, and no stage performs transport.
The wire schema follows Ollama's official [tool-calling contract](https://docs.ollama.com/capabilities/tool-calling).

`Compare-PowerShellWorkbenchOllamaEvidence.ps1` reads a hash-bound comparison manifest under an explicit evidence root. It verifies each capture, requires an identical prompt and normalized request configuration, evaluates an exact UTF-8 answer hash, and reports wall time, server duration, and token counts separately. Wrong answers are never ranked merely because they are fast; missing metrics are `UNKNOWN`, while hash, path, prompt, or configuration drift is `CONFLICT`. The comparator performs no retry, model call, write, or transport.

`Get-PowerShellWorkbenchStatusDashboard.ps1` reuses the health validator and binds every observed source tree to an independently hash-bound release-provenance file under an explicit root. It reports declared version, found source/cache channels, validated tree identity, commit/ref provenance, and catalog state without writing, executing, or transporting anything. Missing or malformed state is `UNKNOWN`; contradictory version, hash, root, or tree state is `CONFLICT`, with the original health gate names preserved.

```powershell
$preview = & '<plugin-root>\scripts\Invoke-PowerShellWorkbenchOllamaChat.ps1' `
    -Prompt 'Explain this script.' `
    -ModelId 'model-name' `
    -ModelDigest '<independently-recorded-model-digest>'

# Add -Execute only after reviewing the preview and intended local model call.
# Add -EnableReadFileSliceProposal only when the fixed proposal schema is intended.
```

## Useful diagnostics

```powershell
& '<plugin-root>\scripts\Get-PowerShellWorkbenchEnvironment.ps1'

$health = & '<plugin-root>\scripts\Test-PowerShellWorkbenchHealth.ps1' `
    -Distribution @(
        @{ Name = 'git-marketplace'; SourcePath = '<git-plugin-root>'; CachePath = '<git-cache-root>' },
        @{ Name = 'personal'; SourcePath = '<personal-plugin-root>'; CachePath = '<personal-cache-root>' }
    ) `
    -ExpectedVersion '<expected-version>' `
    -NoThrow

if (-not $health.Passed) {
    $health.FailedGates
}

& '<plugin-root>\scripts\Get-PowerShellWorkbenchProjectInventory.ps1' `
    -Root 'C:\ProjectOne','C:\ProjectTwo'

$patchDecision = & '<plugin-root>\scripts\Test-PowerShellWorkbenchPatch.ps1' `
    -PatchPath 'C:\staging\change.patch' `
    -InvocationMode DirectArgument `
    -HostAdapter DedicatedTool

if (-not $patchDecision.Eligible) {
    $patchDecision.FailedGates
}
```

## Repository layout

```text
.agents/plugins/marketplace.json
plugins/powershell-workbench/
```

The marketplace manifest points to `./plugins/powershell-workbench`. Project paths are discovered at runtime and are not stored in this repository.

## Safety

The plugin does not perform elevation, image servicing, installer execution, cache deletion, recovery-media writes, or remote backlog writes unless explicitly requested.

---
name: powershell-project-profile-portal
description: Show and safely update a portable PowerShell Workbench project profile through a human-readable, color-coded terminal portal.
---

# PowerShell Project Profile Portal

Use this skill when a PowerShell-centered project needs a portable configuration hub for its root, component roots, Windows targets, reports, artifacts, or cache paths.

Create an initial `.powershell-workbench/project-profile.json` with `New-PowerShellWorkbenchProjectProfile.ps1`, then show the portal:

```powershell
& $PluginRoot/scripts/Show-PowerShellWorkbenchProjectPortal.ps1
```

Preview explicit, relative-path changes before writing them:

```powershell
& $PluginRoot/scripts/Show-PowerShellWorkbenchProjectPortal.ps1 `
  -ProjectRoot '..' `
  -ComponentRoot @{ Source = 'src'; Tests = 'tests' } `
  -WorkingPath @{ Reports = 'reports'; Cache = '.cache' } `
  -WindowsTarget @('Windows 10', 'Windows 11') `
  -NoWrite
```

Remove `-NoWrite` only after the displayed mapping is approved. The portal changes only the selected JSON profile; it never moves files, mounts images, executes installers, clears caches, or writes recovery media.

For a read-only, hash-bound readiness view, place an optional `project-assessment.json` beside the profile and open the portal with `-AssessmentPath`. Legacy schema `1.0` remains supported. Schema `1.1` binds `source.kind` (`git`, `tree`, `ledger`, or `manifest`), a SHA-256 identity, the profile SHA-256, host state, target applicability, freshness, safe/offline/live/postcondition proofs, and evidence paths anywhere under the resolved project root. Missing, drifted, or malformed evidence stays failed or unknown; the portal never promotes it to PASS.

Create a schema 1.1 sidecar as a preview first; it defaults every target to `NOT_RUN` and never infers `PASS`:

```powershell
& $PluginRoot/scripts/New-PowerShellWorkbenchProjectAssessment.ps1 `
  -ProjectRoot 'C:\Project' `
  -NoWrite
```

Use `-Write` only after reviewing the identity and target plan. For a compact read-only overview, use `Invoke-PowerShellWorkbenchDoctor.ps1`; its runtime state is `SKIPPED` by default, so add `-IncludeRuntimeProbe` only when a local child-PowerShell version/architecture probe is desired. Provide explicit distribution evidence when installation equivalence is required.

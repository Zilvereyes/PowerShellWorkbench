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

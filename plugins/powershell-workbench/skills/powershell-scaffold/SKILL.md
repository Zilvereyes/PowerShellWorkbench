---
name: powershell-scaffold
description: Generate reusable PowerShell scripts, functions, modules, manifests, tests, contracts, documentation, lint configuration, and CI files for Windows PowerShell 5.1 and PowerShell 7.
---

# PowerShell Scaffold

Use this skill when the user asks to create a PowerShell component or a supporting project artifact.

1. Confirm the artifact kind, name, destination, and project profile from the request or local context. Never assume a project lives at a machine-specific absolute path.
2. Read `references/artifact-catalog.md` to select the artifact and `references/project-profiles.md` when a project profile applies.
3. Run `../../scripts/New-PowerShellArtifact.ps1` with explicit arguments. Treat `Destination` as a directory. Pass `-ProjectRoot` only when discovery cannot identify the intended project.
4. Never overwrite an existing file unless the user explicitly requested replacement and `-Force` is passed.
5. Keep generated PowerShell valid in both Windows PowerShell 5.1 and PowerShell 7. Do not introduce PowerShell 7-only syntax unless requested and clearly documented.
6. Report the generated path and any values the user still needs to customize. Run validation only when requested.

Templates are packaged in `assets/templates/`. Do not use Template Creator for code templates; it is reserved for supported document, spreadsheet, presentation, image, email, and site artifacts.

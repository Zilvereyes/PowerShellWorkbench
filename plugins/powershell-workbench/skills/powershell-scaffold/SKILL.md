---
name: powershell-scaffold
description: "Generate, extract and compose registered PowerShell components and mixed-language artifacts through archive-first lookup, dependency contracts, parser IDs and a mandatory pre-execution checkpoint."
---

# PowerShell Scaffold

Use this skill when the user asks to create a PowerShell component or a supporting project artifact.

1. Confirm the artifact kind, name, destination, and project profile from the request or local context. Never assume a project lives at a machine-specific absolute path.
2. Read `references/artifact-catalog.md` to select the artifact and `references/project-profiles.md` when a project profile applies.
3. Search the selected project archive first using the component pipeline; compare purpose/contracts before choosing reuse, adaptation or new code. Run `../../scripts/New-PowerShellArtifact.ps1` with explicit arguments for whole artifacts. Treat `Destination` as a directory. Pass `-ProjectRoot` only when discovery cannot identify the intended project.
4. For reusable code fragments, use `../../scripts/New-PowerShellWorkbenchFragmentTemplate.ps1` to extract explicitly selected function or `#region` fragments, then `../../scripts/Join-PowerShellWorkbenchFragmentTemplate.ps1` to compose them. Both commands default to preview/no-write and must preserve source SHA-256 evidence.
5. Never overwrite an existing file unless the user explicitly requested replacement and `-Force` is passed.
6. Keep generated PowerShell valid in both Windows PowerShell 5.1 and PowerShell 7. Do not introduce PowerShell 7-only syntax unless requested and clearly documented.
7. Apply [component-pipeline.md](references/component-pipeline.md) to every generated executable artifact, including small fragments, adapted code, tests, functions, scripts and modules. This user-requested checkpoint is mandatory before execution; broader lint/security scans remain opt-in.
8. Read [language-docs.md](references/language-docs.md) for language documentation and parser routing. Record unsupported and unavailable parsers honestly; never execute source as a syntax test.
9. Report component IDs, hashes, archive locations, unresolved dependencies and exact validation scope. No global OS/host interception is supplied: enforce the checkpoint in every Workbench-controlled generation/execution path.

Whole-artifact templates are packaged in `assets/templates/`. Code-fragment templates are PowerShell Workbench JSON artifacts generated from explicit local source selectors; do not use the generic Template Creator for executable code templates.

Executable whole-artifact generation and persisted fragment/composition helpers now register draft components. They require Python 3.10+ (`-PythonExecutable` selects the installed runtime), an explicit or project-local `.workbench/components` archive, and subsequent contract review plus the gate. Generation never authorizes execution. Existing fragments without component pins must be re-registered before a verified assembly can be used.

Read [file-types.md](references/file-types.md) for game-tooling/native file and dialect routing.

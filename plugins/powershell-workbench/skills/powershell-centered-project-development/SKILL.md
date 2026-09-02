---
name: powershell-centered-project-development
description: Develop mixed-language projects where Windows PowerShell 5.1 or PowerShell 7 is the primary automation, orchestration, installation, build, or recovery layer.
---

# PowerShell-Centered Project Development

Use this skill when a project combines PowerShell with Python, Node, .NET, native tools, web assets, JSON/YAML, Markdown, or other formats.

1. Run `../../scripts/Resolve-PowerShellWorkbenchContext.ps1` from the active workspace and use its `Technologies` result as a fast initial map. Inspect repository manifests and entry points before making cross-stack decisions.
2. Treat PowerShell 5.1 and PowerShell 7 as equal supported hosts. Keep shared scripts on their common syntax surface and isolate host-specific behavior behind explicit capability checks.
3. Preserve native component ownership: Python dependencies stay in Python metadata, Node dependencies in `package.json`, .NET dependencies in project files, and schema/config rules with their corresponding formats.
4. Use PowerShell as the orchestration boundary only where it adds value. Exchange structured data instead of scraping display output, preserve process exit codes, and avoid shell-constructed command strings when argument arrays are available.
5. Apply templates from `powershell-scaffold` for PowerShell, JSON/YAML, Markdown, and CI support. Do not force a PowerShell template onto a non-PowerShell component.
6. Route requested validation through `powershell-quality-gate`, selecting the smallest native checks for the changed technologies. MegaLinter is an optional broad aggregator, not a replacement for repository-declared tools.
7. Do not add, upgrade, or publish dependencies, packages, Actions, or external services unless the user explicitly requests that change.

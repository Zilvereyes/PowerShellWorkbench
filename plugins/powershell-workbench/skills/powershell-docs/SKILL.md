---
name: powershell-docs
description: Research PowerShell language, engine, module, compatibility, and tooling questions from official Microsoft documentation with explicit version scope.
---

# PowerShell Docs

Use the `powershell` domain in `../../assets/documentation-source-catalog.json` as the discovery boundary.
Validate that catalog first with `../../scripts/Test-PowerShellWorkbenchDocumentationCatalog.ps1` and an independently
recorded catalog SHA-256. A stale, drifted, malformed, or unknown catalog is not trusted.

- Open the relevant current Microsoft Learn page before making a claim that can change between PowerShell versions.
- State the target edition and version: Windows PowerShell 5.1, a specific PowerShell 7 release, or both.
- Prefer language and module reference over blogs. Treat blogs and examples as secondary context, not contract authority.
- Separate documented behavior from locally observed behavior. Use a bounded local probe only when the user authorizes it.
- Cite the exact source page used. Do not present catalog membership as proof that the current page still says the same thing.
- Documentation research never authorizes script execution, installation, profile changes, publication, or transport.

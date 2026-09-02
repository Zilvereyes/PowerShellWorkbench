# Project profiles

Resolve the active project with `../../scripts/Resolve-PowerShellWorkbenchContext.ps1`. It walks upward from the active path, then checks an optional registry at `%USERPROFILE%\.config\powershell-workbench\projects.json` or the path in `POWERSHELL_WORKBENCH_PROJECTS`. Do not require any path from another workstation.

## Generic

Use portable paths, explicit exports, comment-based help, structured objects, and Pester 5 syntax. Keep implementation compatible with Windows PowerShell 5.1 and PowerShell 7. When PowerShell orchestrates Python, Node, .NET, native tools, web assets, or data files, preserve the native component boundary and pass structured data through files, streams, or explicit process arguments.

## RecoveryToolkit

Identify this profile by `RecoveryToolkit.psd1` or explicit selection. Use split public functions in domain folders, private helpers under `Private`, underscore-based `Test_<Name>.<Type>.ps1` names, explicit exports, local safe-path boundaries, contract-first behavior, and synthetic temporary data for write-oriented tests. Preserve non-executable servicing and staging contracts.

## WingetDownloader

Identify this profile by `WingetDownloader.psd1` or explicit selection. Treat `WingetDownloader.psm1` and `WingetDownloader.psd1` as authoritative. Use `WD`-prefixed helpers, structured status and error objects, deterministic cache/hash handling, explicit exports, and Pester coverage. The chat knowledge base and backlog are secondary evidence only.

## Optional project registry

Use this shape only when ancestor discovery is insufficient:

```json
{
  "projects": [
    { "name": "RecoveryToolkit", "profile": "RecoveryToolkit", "path": "D:\\Projects\\RecoveryToolkit" },
    { "name": "WingetDownloader", "profile": "WingetDownloader", "path": "D:\\Modules\\WingetDownloader" }
  ]
}
```

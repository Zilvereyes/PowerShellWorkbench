# Artifact catalog

`New-PowerShellArtifact.ps1` accepts these `-Kind` values:

| Kind                     | Output                                                                                      |
|--------------------------|---------------------------------------------------------------------------------------------|
| `AdvancedFunction`       | `<Name>.ps1`; uses the private variant when the destination is inside a `Private` directory |
| `Script`                 | `<Name>.ps1`                                                                                |
| `Module`                 | `<Name>.psm1`                                                                               |
| `Manifest`               | `<Name>.psd1` with an explicit, empty export list                                           |
| `PesterBasic`            | Profile-appropriate basic test filename                                                     |
| `PesterSynthetic`        | Profile-appropriate synthetic test filename with temporary-path cleanup                     |
| `PesterContract`         | Profile-appropriate source-contract test filename                                           |
| `JsonContract`           | `<Name>.contract.json`                                                                      |
| `MarkdownDecision`       | `ADR-<Name>.md`                                                                             |
| `MarkdownHelp`           | `about_<Name>.md`                                                                           |
| `PSScriptAnalyzerConfig` | `PSScriptAnalyzerSettings.psd1`                                                             |
| `MegaLinterConfig`       | `.mega-linter.yml`                                                                          |
| `GitHubWorkflow`         | `powershell-quality.yml`                                                                    |

The generator replaces `NAME`, `PROFILE`, `DATE`, `GUID`, `PROJECT_ROOT`, `PROJECT_ROOT_JSON`, `PATH_HINT`, `TEST_STYLE`, `LOGGING_GUIDANCE`, and `SAFETY_GUIDANCE` tokens.
`PROJECT_ROOT_JSON` is a complete JSON string literal so Windows paths remain valid. It discovers a project root from the destination or optional per-machine registry; `-ProjectRoot` is an explicit override. Configuration artifact kinds still require `-Name` so generated metadata remains attributable.

## Fragment templates

`New-PowerShellWorkbenchFragmentTemplate.ps1` creates hash-bound JSON templates from explicitly selected PowerShell functions and `#region` blocks. It defaults to preview/no-write and records the source relative path, source SHA-256, fragment line numbers, fragment text, and fragment SHA-256.

`Join-PowerShellWorkbenchFragmentTemplate.ps1` composes one or more fragment templates into a PowerShell script. It verifies that every source file still matches the recorded SHA-256, rejects conflicting duplicate fragments, validates the composed script with the PowerShell parser, and defaults to preview/no-write. Generation performs no execution or transport.

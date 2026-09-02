# Artifact catalog

`New-PowerShellArtifact.ps1` accepts these `-Kind` values:

| Kind | Output |
|---|---|
| `AdvancedFunction` | `<Name>.ps1`; uses the private variant when the destination is inside a `Private` directory |
| `Script` | `<Name>.ps1` |
| `Module` | `<Name>.psm1` |
| `Manifest` | `<Name>.psd1` with an explicit, empty export list |
| `PesterBasic` | Profile-appropriate basic test filename |
| `PesterSynthetic` | Profile-appropriate synthetic test filename with temporary-path cleanup |
| `PesterContract` | Profile-appropriate source-contract test filename |
| `JsonContract` | `<Name>.contract.json` |
| `MarkdownDecision` | `ADR-<Name>.md` |
| `MarkdownHelp` | `about_<Name>.md` |
| `PSScriptAnalyzerConfig` | `PSScriptAnalyzerSettings.psd1` |
| `MegaLinterConfig` | `.mega-linter.yml` |
| `GitHubWorkflow` | `powershell-quality.yml` |

The generator replaces `NAME`, `PROFILE`, `DATE`, `GUID`, `PROJECT_ROOT`, `PROJECT_ROOT_JSON`, `PATH_HINT`, `TEST_STYLE`, `LOGGING_GUIDANCE`, and `SAFETY_GUIDANCE` tokens. `PROJECT_ROOT_JSON` is a complete JSON string literal so Windows paths remain valid. It discovers a project root from the destination or optional per-machine registry; `-ProjectRoot` is an explicit override. Configuration artifact kinds still require `-Name` so generated metadata remains attributable.

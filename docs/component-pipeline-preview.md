# Component pipeline preview: 0.9.0-beta.1

PowerShell Workbench is the owning plugin and Git marketplace package. No separate plugin
is required for these capabilities. The previous Component Forge experiment is not a dependency.

## Implemented foundation

- Archive-first generation instructions and immutable component UUID/version/byte-hash records.
- Search, registration, dependency pin and lineage records; reviewed/resolved contract checkpoint.
- Fresh parser checks, snapshot/source comparison, cycle/missing-dependency and hash rejection.
- Draft registration in whole-artifact, fragment extraction and fragment composition helpers.
- Non-executing PowerShell AST inventory; native syntax adapters for PowerShell, XML, Python,
  strict JSON, Node JavaScript and Lua. Native tools must actually be available.
- Registered unavailable adapters for Batch/CMD, TypeScript, C#, YAML, HTML, CSS, Bash, SQL and TOC.
- Fifteen new language documentation skills and explicit game-tooling file/dialect routing.
- Source/channel guidance joining the existing Git marketplace and account-plugin release process.

## Validation performed

On Linux with Python and a temporary PowerShell 7.4.13 runtime:

- 22 Python contract tests passed, including non-execution, parser failures, immutable versions,
  cycle/missing-pin/hash rejection, actual-source mutation, locking, lineage and catalog hashes.
- Workbench structural validation passed for every packaged PowerShell script.
- Existing scaffold, documentation and documentation-catalog contract tests passed.
- New AST and generated-component registration contracts passed.
- Existing portable marketplace clean-install, upgrade and rollback contract tests passed.
- `git diff --check` passed.

Windows PowerShell 5.1 and Windows-specific runtime behavior remain pending the repository's
Windows validation workflow. PSScriptAnalyzer and full MegaLinter results are not claimed here.
Lua's external luac backend is implemented but was not exercised with an installed Lua compiler.
A complete behavioral certification or exhaustive data-flow analysis is not implemented.

## Plugin Eval

Plugin Eval's start/analyze/compare workflow was run on the existing 0.8.2 package and this
candidate. Both static scores are 0/100, grade F. The comparison introduces no new failing
checks; it retains existing listing-field and aggregate token-budget failures. This is a
static rubric result, not an executable parser/test result or a release approval.

The existing evaluator requires website/privacy-policy/terms URLs and applies aggregate
budgets to a broad multi-skill plugin. No legal URLs were invented, no checks were disabled,
and existing workflows were not removed to improve the score. Adding languages increases
trigger/invocation/deferred estimates; real task-token usage has not been measured.

## Limits and release path

Contract review is an explicit agent declaration; it does not prove complete dependency closure.
AST inventory does not automatically untangle shared scope, aliases, closures, reference mutation
or dynamic command resolution. Unknowns must stay unresolved. The checkpoint cannot intercept
external shells or guarantee that later files are unchanged; freeze/recheck execution bytes.

The Git marketplace already points to plugins/powershell-workbench. Review and merge the
candidate only after required Windows/CI checks pass, then choose a reviewed immutable ref.
Generate the account-plugin archive from that exact commit and update its existing identity.
Refreshing the Git marketplace does not automatically update an account installation, and a
pinned Git ref does not move to another release tag. Verify each machine/host's installed tree
before reporting an update complete.

# Component pipeline v1

PowerShell Workbench is the owning tool. Do not route this workflow into a separate plugin.
Mutable project archives live in a chosen project, never in the plugin cache. Python 3.10+
is required for the packaged archive worker. Do not silently install missing runtimes.

## Commands

Use argument arrays from PowerShell; Python commands below show the CLI surface. Paths are
examples to replace with actual project paths. The worker is scripts/workbench_components.py.

```text
python workbench_components.py search --archive <archive> --query "purpose keywords"
python workbench_components.py parse --source <file> --language powershell
python workbench_components.py register --archive <archive> --source <file> --language powershell --purpose "specific purpose" --kind function --contract <contract.json>
python workbench_components.py gate --archive <archive> --component-id <uuid> --version 1.0.0 --source <actual-file-to-be-run>
```

PowerShell entrypoint: `Invoke-PowerShellWorkbenchComponent.ps1 -Action <action>
-ArgumentList <string-array> -PythonExecutable <installed-python>`.

Search first. Compare compatible inputs/outputs, dependencies, side effects, runtime target,
provenance and checks; similarity scoring is keyword ranking, not semantic proof. Reuse an
unchanged registration; adapt a differing purpose with a new UUID and --derived-from JSON
pins. For a compatible revision use --component-id plus an increased --version. Never
rewrite a published ID/version. Source records are immutable snapshots with exact-byte hashes.
The registration lock serializes writes; an interrupted lock requires inspection, not automatic deletion.

## Contract

Required JSON fields: inputs, outputs, bindings, effects, unresolved (arrays), reviewed (boolean).
A reviewed contract is an agent's explicit review declaration, not an automatic semantic proof.
Document each input's type/default/validation, output shape/stream, scope binding read/write,
external command/module, filesystem/registry/network effects, error/exit/return semantics,
elevation/reboot needs, target runtime and unresolved observations. Optional fields may add
provenance, license, tests, exports and version-specific details. Never store secrets.

Start generated templates with reviewed=false and unresolved items. After reviewing, register
a new version with a resolved contract. --dependencies and --derived-from accept paths to
JSON arrays of exact componentId/version/sha256 pins. Register both assembly and members;
missing member provenance or pins must remain unresolved, never silently asserted complete.

## Dependency extraction

Use Get-PowerShellWorkbenchCodeAnalysis.ps1 for a non-executing AST inventory of variables,
assignments, functions and commands. It is not a complete scope/data-flow analyzer. Examine
callers, script/global/env/preference/automatic variables, aliases, splatting, closures,
reference mutation, dot-sourcing, dynamic invocation, pipeline and error streams and finally
blocks. Turn implicit inputs/outputs into explicit parameters/results only when behavior is
preserved. Keep inseparable statements as a composite unit. Record unknown dependencies.

Legacy fragment helpers preserve source hashes and now register persisted fragments. A
composition registers its own assembly ID and member pins. Legacy fragments without pins
remain draft; re-extract/register them before resolving the assembly contract. Assembly
ordering, exports, variable collisions and behavior require review/tests; syntax alone is
insufficient. Modules must not acquire import-time mutations.

## Mandatory checkpoint before execution

For any generated or changed executable code: search -> adapt/generate -> register -> review
contract and dependency closure -> parser/test as applicable -> gate using exact current
source bytes -> authorized execution through the target project's existing runner. On any
edit, re-register and repeat. For multi-file modules check all executable members and assembly
pins, not just the entry point. Verify the gate's nonzero exit code blocks the caller.

Gate rehashes every snapshot, verifies exact dependency pins, rejects cycles and missing
records, requires reviewed/resolved declarations and reruns each native syntax adapter.
It compares the actual target file to its registered bytes. A gate is a point-in-time check;
freeze the execution artifact or recheck immediately before launch. It does not itself launch
code, grant operational authorization, prove behavioral safety or intercept external shells.
Unsupported/missing parsers remain UNAVAILABLE and block the checkpoint; no bypass flag exists.
Run target-specific behavior tests before operational reuse, mocking system mutations.

## Parser components

Read ../../../assets/component-parser-catalog.json relative to the skill references folder.
Each of 15 language adapters has a stable UUID and exact implementation hash. PowerShell
uses the installed pwsh or powershell.exe AST parser; XML uses well-formedness parsing with
DTD/entities prohibited; Python uses ast.parse; JSON is strict; JavaScript uses Node --check
on frozen .cjs/.mjs input; Lua uses luac -p. Runtime versions differ from language coverage:
record the actual target version and repeat tests on each supported host. Batch/CMD,
TypeScript, C#, YAML, HTML, CSS, Bash and SQL have registered adapter contracts whose native
implementations are not yet bundled. Never mark these reserved contracts as working parsers.

Built-in parser catalog is read-only package metadata; project components use the mutable
archive worker. Catalog hashes are integrity labels, not signatures or an untrusted-user sandbox.

---
name: powershell-safe-editing
description: Make precise, low-churn edits to compact, generated, or one-line PowerShell and mixed-language files, and diagnose patch payload, encoding, or invocation failures without executing the patch.
---

# PowerShell Safe Editing

Use this skill when a target file is compacted, generated, mostly one line, has dense semicolon-delimited PowerShell, or an exact patch has failed because its context did not match. Also use it when a patch wrapper reports pipeline encoding, stdin, shell-text, multiline-argument, or patch-envelope failures. Do not use it for ordinary readable source edits.

1. Identify the exact files and the smallest change before editing. Preserve existing encoding, line endings, and unrelated formatting.
2. Read only the smallest relevant region and choose an anchor that includes stable nearby syntax, not whitespace or a long fragile line.
3. Make one logical change per patch. Split independent files into separate patches so one mismatched anchor does not block unrelated work.
4. For dense one-line code, use a narrow replacement only when the old text is unique and the expected replacement count is exactly one. Fail closed if it is zero or greater than one.
5. Do not apply broad regex rewrites, whole-file formatting, or minifier output just to make a patch succeed. They obscure review and can change semantics.
6. After a rejected patch, inspect the smallest failed anchor, account for the actual text or line ending, then retry with a smaller patch. Do not repeat the identical patch.
7. Keep validation proportional to the requested work. Parse, test, lint, or run quality gates only when requested or when a changed deterministic helper requires direct verification.

For patch transport failures, separate payload validity from host capability:

1. Run `scripts/Test-PowerShellWorkbenchPatch.ps1` with `-PatchText` or `-PatchPath`, the intended `-InvocationMode`, and the actual `-HostAdapter`. This is read-only and never applies or transports the patch.
2. Proceed only when `Eligible` is true. Preserve `PatchSha256` when reporting or handing off the validated payload, and propagate every `FailedGates` value exactly.
3. Submit the complete payload through a dedicated patch tool or native executable as one direct argument. Do not pipe it, send it through stdin, or evaluate it as shell text.
4. Treat a Windows batch wrapper as multiline-unsafe. If a verified payload reached such a wrapper, stop retrying the identical patch and report `HostAdapterMultilineArgumentSafe`; do not work around it with `Invoke-Expression` or lossy quoting.

For PowerShell, preserve Windows PowerShell 5.1 and PowerShell 7 compatibility unless the user explicitly narrows the target runtime.

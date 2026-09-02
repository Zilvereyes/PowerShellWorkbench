---
name: powershell-safe-editing
description: Make precise, low-churn edits to compact, generated, or one-line PowerShell and mixed-language files when ordinary patch anchors are fragile.
---

# PowerShell Safe Editing

Use this skill when a target file is compacted, generated, mostly one line, has dense semicolon-delimited PowerShell, or an exact patch has failed because its context did not match. Do not use it for ordinary readable source edits.

1. Identify the exact files and the smallest change before editing. Preserve existing encoding, line endings, and unrelated formatting.
2. Read only the smallest relevant region and choose an anchor that includes stable nearby syntax, not whitespace or a long fragile line.
3. Make one logical change per patch. Split independent files into separate patches so one mismatched anchor does not block unrelated work.
4. For dense one-line code, use a narrow replacement only when the old text is unique and the expected replacement count is exactly one. Fail closed if it is zero or greater than one.
5. Do not apply broad regex rewrites, whole-file formatting, or minifier output just to make a patch succeed. They obscure review and can change semantics.
6. After a rejected patch, inspect the smallest failed anchor, account for the actual text or line ending, then retry with a smaller patch. Do not repeat the identical patch.
7. Keep validation proportional to the requested work. Parse, test, lint, or run quality gates only when requested or when a changed deterministic helper requires direct verification.

For PowerShell, preserve Windows PowerShell 5.1 and PowerShell 7 compatibility unless the user explicitly narrows the target runtime.

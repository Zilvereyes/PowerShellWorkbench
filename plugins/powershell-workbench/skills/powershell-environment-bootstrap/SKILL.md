---
name: powershell-environment-bootstrap
description: Diagnose PowerShell, Codex CLI, Node/npm, Git, GitHub CLI, Docker, winget, and PATH availability on Windows before giving installation or plugin setup commands.
---

# PowerShell Environment Bootstrap

Use this skill for missing-command, PATH, workstation bootstrap, plugin-installation, or cross-laptop setup problems.

1. Run `../../scripts/Get-PowerShellWorkbenchEnvironment.ps1` before prescribing a fix.
2. Distinguish `missing executable`, `installed but not on PATH`, `current shell has stale PATH`, and `application-private binary`. Adding a directory to PATH never installs a program.
3. Treat version-specific Codex Desktop binary folders as diagnostic evidence, not stable persistent PATH targets. Prefer the current supported standalone Codex CLI installation when a terminal command is required.
4. Keep installation optional and explicit. Diagnose first; install, change persistent PATH, authenticate, or add a marketplace only when requested.
5. After an approved install, verify with `Get-Command`, the tool's version command, and a newly opened shell when persistent environment variables changed.
6. For another laptop, separate three prerequisites: Codex CLI availability, Git/network access to the marketplace, and plugin installation. Do not assume Codex Desktop exposes `codex` globally.

# Contributing to PowerShell Workbench

## Before opening a pull request

- Start from current `main` in a dedicated branch or worktree.
- Keep changes small, portable, and free of machine-specific paths or secrets.
- Preserve the declared Windows PowerShell 5.1 and PowerShell 7 compatibility boundary.
- Keep live provider switching, Desktop lifecycle actions, elevation, clipboard writes, live
  model calls, and transport behind separate explicit operations.

## Validation

Run the relevant contract tests and structural validation in both Windows PowerShell 5.1 and
PowerShell 7. Run PSScriptAnalyzer when available. GitHub Actions must pass the repository's
Validate PowerShell Workbench and MegaLinter checks before merge.

## Pull requests

Describe the problem, the safety boundary, validation evidence, and deliberate non-actions.
Do not commit generated local evidence, credentials, personal paths, or unreviewed release
artifacts. Report potential security issues privately as described in [SECURITY.md](SECURITY.md).

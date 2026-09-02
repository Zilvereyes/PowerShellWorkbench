---
name: game-tooling-development
description: Develop PowerShell-centered game tooling that combines Lua addons, VS Code extensions, Node, .NET, native tools, CASC/game data, or web documentation.
---

# Game Tooling Development

Use this skill for game-data utilities, World of Warcraft addon tooling, editor extensions, exporters, local data services, and similar mixed-language projects.

1. Run `../../scripts/Resolve-PowerShellWorkbenchContext.ps1` and inspect actual manifests and entry points. Treat PowerShell as orchestration, not as a replacement for Lua, TypeScript, .NET, native, or data-format ownership.
2. For WoW addons, treat `.toc` metadata, Lua load order, events, widget handlers, secure APIs, SavedVariables, and client-version changes as separate contracts.
3. For CASC, exporters, and local game-data services, preserve binary-format boundaries, build identity, cache integrity, path safety, and deterministic provenance.
4. Use current upstream documentation when exact APIs or events matter. Never rely on remembered API signatures when they may vary by game build.
5. Keep generated or extracted assets out of initial scans unless explicitly scoped. Do not redistribute proprietary game data or credentials.
6. Route checks to each component's declared toolchain and use `powershell-quality-gate` only for requested aggregate validation.
7. Read `references/wow-ecosystem.md` for the user-provided starting sources and project signals.

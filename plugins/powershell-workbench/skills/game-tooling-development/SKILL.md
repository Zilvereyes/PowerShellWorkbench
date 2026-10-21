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


## Registered file types and generation

Route .ps1/.psm1/.psd1, .lua, .xml, .toc, .json/.jsonc, .js/.cjs/.mjs, .ts/.tsx, .cs/.csproj, .cmd/.bat, HTML/CSS and schemas to their native contracts. JSONC is not strict JSON; JSX/TSX is not plain JavaScript; project XML is not proof a build succeeds. Binary CASC/BLP/ADT/WDT/DBC/DB2 assets require format-specific readers and game-build evidence; never treat a text parser as validation. Use the file-type routing reference under powershell-scaffold.

Apply ../powershell-scaffold/references/component-pipeline.md to every generated executable member and assembly before execution. Capture WoW client branch/build, Lua runtime, TOC load order, XML handlers and external API dependencies. Missing native/dialect parsers block the checkpoint; explicit data-only assets use format validation rather than execution clearance.

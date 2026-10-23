# Release channels

Canonical repository: https://github.com/Zilvereyes/PowerShellWorkbench
Marketplace: .agents/plugins/marketplace.json -> plugins/powershell-workbench.
Keep that portable path and marketplace/plugin names stable.

1. Start from current main on a dedicated branch. Review applicable repository guidance.
2. Update source, docs, native adapters, fixtures, component catalogs and both manifests together.
3. Run Python contract tests, Windows PowerShell 5.1/PowerShell 7 tests, PSScriptAnalyzer and required CI. Missing hosts remain unverified; do not tag a validated release before required CI passes.
4. Merge the reviewed change, then select an immutable reviewed commit/tag. Build the account-plugin archive from that exact plugin directory, excluding Git metadata, caches and machine-specific evidence. Upload it to the existing account plugin with a guarded release ID; never create another Workbench identity.
5. On each computer inspect codex --version, codex plugin marketplace --help and the configured marketplace list before refresh. Use the documented marketplace add/upgrade operations supported by that installed host. Immutable pins do not advance to a new release tag automatically: select the new reviewed ref explicitly. Do not silently switch a pinned source to main.
6. In ChatGPT Desktop/Codex local clients refresh the chosen marketplace and start a new task; verify the installed version and tree identity using the existing health/status tools. An account plugin update and a Git marketplace upgrade are separate operations. Do not claim either machine updated without observed evidence. Web/account installations cannot directly launch a Windows-local runtime from a skill alone.

Official host documentation checked 2026-10-20: https://developers.openai.com/plugins/build/plugins
This documents local marketplace add/list/upgrade/remove and Desktop discovery. Check the installed CLI help before any add/remove sequence; do not uninstall merely to refresh.

Private project archives, registry paths and host settings are not bundled into the public plugin repository. Synchronize reusable project component archives through a deliberately selected Git project separately. Keep account channel and marketplace channel provenance visible if both installations are enabled, and diagnose duplicate roots instead of editing version caches.

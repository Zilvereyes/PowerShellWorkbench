---
name: powershell-agent-harness-development
description: Build or review PowerShell orchestration for local or hosted AI models, coding agents, capability registries, evaluations, checkpoints, session exports, and provider switching.
---

# PowerShell Agent Harness Development

Use this skill when PowerShell controls a model endpoint, coding-agent CLI, capability registry, evaluation harness, provider profile, context checkpoint, or session export.

1. Read [references/agent-harness-patterns.md](references/agent-harness-patterns.md) for the applicable modes only.
2. Separate deterministic authority from model assistance. Paths, manifests, permissions, hashes, timestamps, approval state, and pass/fail decisions must be validated by code; model output may summarize or classify only after validation.
3. Bind evidence to model identifier and digest, provider/endpoint, host, context configuration, project profile, capability version, fixture hash, and timestamp. Do not generalize one successful run to another configuration.
4. Permit loopback endpoints by default. Treat remote endpoints, silent cloud fallback, credential transmission, and connector writes as separate capabilities requiring explicit authorization and evidence.
5. Make provider/config changes reversible: preflight, exact backup, scoped edit, post-check, explicit restore, and actionable failure state. Never leave a partially switched profile reported as ready.
6. Preserve raw evidence and produce structured JSON results before Markdown summaries. Reject empty output, malformed structured output, unsafe paths, stale evidence, and unknown status values.
7. Use mock/contract tests before live model calls. Live tests must have bounded repetitions, timeouts, no automatic destructive retries, and persisted failure classification.

## Packaged artifacts

- Use `../../scripts/Invoke-PowerShellWorkbenchCodexJson.ps1` to capture a bounded `codex exec --json` run. It requires PowerShell 7 because reliable argument passing, asynchronous waits, cancellation, and process-tree termination use modern .NET APIs.
- Use `../../scripts/Test-PowerShellWorkbenchCodexEvidence.ps1` separately to validate the capture. A process exit code of zero and a plausible final message are insufficient when any tool, policy, approval, schema, or turn event failed.
- Copy and adapt [assets/templates/provider-switch-transaction.ps1.tmpl](assets/templates/provider-switch-transaction.ps1.tmpl) for reversible provider configuration changes.
- Windows PowerShell 5.1 can run the evidence validator, contract tests, and provider-switch template, but it must not be used for the bounded runner.

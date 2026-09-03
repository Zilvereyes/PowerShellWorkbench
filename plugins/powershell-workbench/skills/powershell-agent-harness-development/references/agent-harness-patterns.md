# Agent harness patterns

## Registry and policy

- Give every JSON registry a `schemaVersion`, stable identifiers, explicit status vocabulary, and documented evidence rules.
- Keep a vendor-neutral core policy and apply project-specific overlays only after the active root/profile is identified.
- Default missing profiles and unavailable capabilities to conservative, non-mutating behavior.

## Endpoint and provider controls

- Parse endpoints as URIs and require an exact loopback host for local-only operation.
- Record the resolved model digest and effective context, not only the requested model name.
- Never silently switch provider after empty output, timeout, denial, or unavailable capability.

## Evaluation evidence

- Use immutable fixtures or record fixture hashes.
- Separate synthetic schema/tool-call evaluation from real tool execution.
- Require consecutive passes where variance matters and retain every failed run.
- Record latency, output validity, safety-boundary behavior, and resource observations independently.

## Context and sessions

- Export sessions to a non-executable format and redact credentials, tokens, cookies, and connector secrets.
- Checkpoints must preserve source identity, unresolved decisions, safety constraints, and a reload canary.
- Publishing a checkpoint requires deterministic validation; model-produced summaries are candidates, not trusted state.
- Generate portable handoffs as validated local JSON first and derive Markdown from the same canonical payload. Keep task, Drive, GitHub, and connector transport outside the generator.

## Configuration lifecycle

- Preflight required files and runtime availability.
- Back up exact configuration before editing.
- Modify only owned keys or clearly marked blocks.
- Compare effective state after editing.
- Provide an explicit restore operation and preserve unrelated settings.
- Journal each provider phase before and after mutation. A resume decision is read-only and must verify journal freshness, phase history, configuration and backup hashes, provider/model/context identity, owned keys, and effective owned state.
- Treat a verified `Ready` profile as already ready. Treat `ProviderCommitted` and `PostCheckPending` as post-check work, never as authority to repeat the provider edit.

## Named gate groups

- Give every gate and group a stable exact name. Reject duplicate gates, duplicate groups, unknown gate references, and non-boolean gate results.
- Select the narrowest group authorized for the action. A loopback runtime preparation group may omit host elevation and clipboard gates; host certification must retain them.
- Preserve failed-gate names and declaration order so callers can diagnose the precise blocking boundary.

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

## Configuration lifecycle

- Preflight required files and runtime availability.
- Back up exact configuration before editing.
- Modify only owned keys or clearly marked blocks.
- Compare effective state after editing.
- Provide an explicit restore operation and preserve unrelated settings.

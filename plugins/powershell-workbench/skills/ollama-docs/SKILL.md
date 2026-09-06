---
name: ollama-docs
description: Research Ollama API, CLI, model, runtime, tool-calling, structured-output, context, and integration behavior from official Ollama documentation.
---

# Ollama Docs

Use the `ollama` domain in `../../assets/documentation-source-catalog.json` as the discovery boundary.
Validate that catalog first with `../../scripts/Test-PowerShellWorkbenchDocumentationCatalog.ps1` and an independently
recorded catalog SHA-256. A stale, drifted, malformed, or unknown catalog is not trusted.

- Start with the official `llms.txt` index when the relevant page is not already known, then open the exact current page.
- Separate local loopback API behavior, Ollama cloud behavior, OpenAI compatibility, CLI behavior, and client-library behavior.
- A model-returned tool call is a proposal. Only client-side execution evidence proves that a tool actually ran.
- Distinguish documented fields from fields observed in a hash-bound response and from capabilities of a specific model.
- Cite the exact source page and state the installed Ollama version when a claim depends on runtime behavior.
- Research never authorizes a model call, model pull or deletion, tool execution, provider switch, network fallback, or transport.

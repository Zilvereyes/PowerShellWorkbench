---
name: microsoft-update-docs
description: Research Windows Update, Microsoft Update, UUP, update policy, deployment, troubleshooting, releases, and build history from official Microsoft sources.
---

# Microsoft Update Docs

Use the `microsoft-update` domain in `../../assets/documentation-source-catalog.json` as the discovery boundary.
Validate that catalog first with `../../scripts/Test-PowerShellWorkbenchDocumentationCatalog.ps1` and an independently
recorded catalog SHA-256. A stale, drifted, malformed, or unknown catalog is not trusted.

- Identify Windows edition, release, build, servicing channel, update type, management plane, and date before answering.
- Separate Windows Update, Microsoft Update, WSUS, Windows Update client policy, Intune or MDM, and release-history claims.
- Re-open the current Microsoft page for build, KB, policy, support, applicability, or lifecycle facts; those facts drift.
- Prefer Microsoft Learn for architecture and policy, and Microsoft Support update history for exact release or KB history.
- Cite the exact page used and state when a conclusion is an inference across multiple official pages.
- Research never authorizes scanning, downloading, installing, hiding, uninstalling, or approving an update or policy change.

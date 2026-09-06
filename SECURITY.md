# Security policy

## Supported versions

Security fixes are made on the current `main` branch and the latest published release.
Older releases may be evaluated case by case, but they are not maintained as a supported
security branch.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability
reporting for this repository when it is available, or contact the repository owner privately.
Include a minimal reproduction, the affected version or commit, expected and observed behavior,
and any relevant safety boundary.

Reports are triaged privately. The project will acknowledge receipt, validate the finding,
coordinate a fix where appropriate, and publish a credit or advisory only after a remedy is
available or the reporter agrees that disclosure is safe.

## Scope

The plugin's PowerShell scripts, skills, templates, marketplace metadata, release artifacts,
and CI configuration are in scope. Live provider switching, Desktop lifecycle control,
elevation, clipboard writes, live model calls, and external transport remain explicitly
authorized operations; a report should identify if a boundary can be bypassed.

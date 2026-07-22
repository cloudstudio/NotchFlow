# Security Policy

## Reporting a vulnerability

Please report security issues **privately** via GitHub → the repository's
**Security** tab → **Report a vulnerability** (GitHub Security Advisories).
Do not open a public issue for anything exploitable.

You can expect an initial response within a few days. Once a fix is available
we'll credit you in the release notes unless you'd rather stay anonymous.

## What NotchFlow touches

NotchFlow is a local observer for coding agents. Its trust boundary is small and
worth stating plainly:

- **It edits agent configuration.** `install.sh` / `notchflow-install` add hook
  entries to `~/.claude/settings.json` (and the Codex config) so the agents emit
  lifecycle events. The install is reversible — remove the `notchflow-hook`
  entries, or see the Uninstall section of the README.
- **It opens a local socket.** The app runs a `BridgeServer` on a Unix-domain
  socket under `~/Library/Application Support/NotchFlow/`, owner-only
  (`chmod 600`). Nothing listens on a network port.
- **It only observes.** NotchFlow never launches or drives your agents, makes no
  outbound network requests, sends no telemetry, and persists nothing off your
  Mac beyond a local state cache.

## The one sharp edge: auto-approve

The **Auto-approve reads** plugin can answer permission prompts for you. It is:

- **Opt-in and off by default** — you turn it on explicitly.
- **Read-only scoped** — it only ever allows a fixed safelist of read-only tools
  (Read, Grep, Glob, LS, WebFetch, WebSearch…). It never approves writes, edits,
  shell, or a question/plan; those always fall through to you.

The exact safelist is `PluginManager.safeTools`, and it is covered by tests
(`Tests/NotchKitTests/AutoApproveGateTests.swift`) precisely because this is the
one place a bug could let an agent act unprompted.

## Builds

Release `.app` bundles are code-signed (and notarized when a Developer ID is
configured); local builds via `Packaging/build-app.sh` are ad-hoc signed for
your machine only.

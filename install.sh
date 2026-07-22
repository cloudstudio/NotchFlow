#!/bin/bash
# NotchFlow — one-command install. Builds the app, installs it, wires the
# Claude Code / Codex hooks so the notch starts monitoring, and launches it.
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Building NotchFlow.app (first build downloads nothing but takes a minute)…"
./Packaging/build-app.sh --install

echo "▸ Installing agent hooks (Claude Code / Codex)…"
~/Applications/NotchFlow.app/Contents/Helpers/notchflow-install || true

echo "▸ Launching…"
open ~/Applications/NotchFlow.app

echo ""
echo "✅ NotchFlow is running — look at your notch. Start a coding agent and it lights up."

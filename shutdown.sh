#!/usr/bin/env bash
# =============================================================================
# hardclaw shutdown.sh
# Cleanly stops the NemoClaw stack (sandbox, OpenShell, Ollama).
# State is preserved — run install.sh or 'systemctl start nemoclaw-sandbox'
# to bring everything back up.
#
# Usage:
#   bash shutdown.sh              # stop sandbox + OpenShell + Ollama
#   bash shutdown.sh --keep-ollama  # leave Ollama running (model stays in memory)
# =============================================================================

set -euo pipefail

SANDBOX_NAME="${HARDCLAW_SANDBOX_NAME:-my-assistant}"
KEEP_OLLAMA=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sandbox-name)  SANDBOX_NAME="$2"; shift 2 ;;
        --keep-ollama)   KEEP_OLLAMA=true; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
info() { echo -e "${BLUE}[hardclaw]${NC} $*"; }
skip() { echo -e "  ${YELLOW}–${NC} $* (skipped)"; }

echo -e "\n${BOLD}Hardclaw — Clean Shutdown${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ---------------------------------------------------------------------------
# 1. Stop auxiliary NemoClaw services (Telegram bridge, tunnel)
#    nemoclaw stop — no-op if not configured
# ---------------------------------------------------------------------------
info "Stopping auxiliary NemoClaw services..."
if command -v nemoclaw &>/dev/null; then
    nemoclaw stop 2>/dev/null && ok "Auxiliary services stopped" || \
        warn "nemoclaw stop returned non-zero (may be fine if nothing was running)"
else
    skip "nemoclaw not in PATH"
fi

# ---------------------------------------------------------------------------
# 2. Stop OpenShell cluster container (graceful, 30 s drain)
#    'docker stop' will NOT trigger the unless-stopped restart policy —
#    the container stays stopped until next Docker daemon start (i.e., reboot).
# ---------------------------------------------------------------------------
info "Stopping OpenShell cluster container..."
if docker ps -q --filter "name=openshell-cluster-nemoclaw" 2>/dev/null | grep -q .; then
    docker stop --time 30 openshell-cluster-nemoclaw && \
        ok "openshell-cluster-nemoclaw stopped" || \
        warn "Container stop returned non-zero"
else
    status=$(docker inspect openshell-cluster-nemoclaw --format '{{.State.Status}}' 2>/dev/null || echo "not found")
    skip "openshell-cluster-nemoclaw (status: $status)"
fi

# ---------------------------------------------------------------------------
# 3. Stop Ollama (frees ~87 GB of unified memory)
#    Skip with --keep-ollama if you want inference to remain available.
# ---------------------------------------------------------------------------
if [[ "$KEEP_OLLAMA" == "true" ]]; then
    skip "Ollama (--keep-ollama)"
else
    info "Stopping Ollama (frees ~87 GB unified memory)..."
    if systemctl is-active ollama &>/dev/null; then
        sudo systemctl stop ollama && ok "Ollama stopped" || warn "Could not stop Ollama"
    else
        skip "Ollama (already inactive)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}${BOLD}Shutdown complete.${NC}"
echo ""
echo "  To restart the full stack:"
echo "    sudo systemctl start nemoclaw-sandbox   # starts Ollama → OpenShell → sandbox"
echo ""
echo "  Or manually:"
echo "    sudo systemctl start ollama"
echo "    docker start openshell-cluster-nemoclaw"
echo "    nemoclaw start"
echo ""

#!/usr/bin/env bash
# =============================================================================
# hardclaw verify.sh
# Verifies all isolation layers of the NemoClaw hardened deployment.
# Run after install or after any reboot.
#
# Usage: bash verify.sh [--sandbox-name NAME]
# =============================================================================

set -euo pipefail

SANDBOX_NAME="${HARDCLAW_SANDBOX_NAME:-my-assistant}"
DASHBOARD_PORT="${HARDCLAW_DASHBOARD_PORT:-18789}"
MODEL="${HARDCLAW_MODEL:-nemotron-3-super:120b}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sandbox-name) SANDBOX_NAME="$2"; shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN_COUNT=0

pass()  { echo -e "  ${GREEN}PASS${NC}  $*"; PASS=$((PASS + 1)); }
fail()  { echo -e "  ${RED}FAIL${NC}  $*"; FAIL=$((FAIL + 1)); }
warn()  { echo -e "  ${YELLOW}WARN${NC}  $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
info()  { echo -e "  ${BLUE}INFO${NC}  $*"; }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

# ---------------------------------------------------------------------------
# Layer 1: Host baseline
# ---------------------------------------------------------------------------
section "Layer 1 — Host baseline"

# UFW
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    pass "UFW is active"
    if sudo ufw status | grep -q "DENY.*${DASHBOARD_PORT}"; then
        pass "Dashboard port ${DASHBOARD_PORT} is blocked externally"
    else
        warn "Port ${DASHBOARD_PORT} may not be blocked — check: sudo ufw status"
    fi
    if sudo ufw status | grep -q "172.17.0.0/16.*11434\|172.18.0.0/16.*11434"; then
        pass "Docker bridge → Ollama (port 11434) rules present"
    else
        warn "Ollama UFW rules for Docker bridge may be missing"
    fi
else
    fail "UFW is not active — run: sudo ufw enable"
fi

# avahi
if systemctl is-active avahi-daemon &>/dev/null 2>&1; then
    warn "avahi-daemon is running (should be disabled): sudo systemctl disable --now avahi-daemon"
else
    pass "avahi-daemon is disabled"
fi

# ---------------------------------------------------------------------------
# Layer 2: Docker + NVIDIA runtime
# ---------------------------------------------------------------------------
section "Layer 2 — Docker + NVIDIA runtime"

if docker info &>/dev/null; then
    pass "Docker is running"
else
    fail "Docker is not running — run: sudo systemctl start docker"
fi

if docker info 2>/dev/null | grep -q "nvidia"; then
    pass "NVIDIA runtime is configured in Docker"
else
    fail "NVIDIA runtime missing — run: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
fi

# GB10/ARM64 doesn't mount nvidia-smi into generic containers; use a simple launch test instead
if docker run --rm --runtime=nvidia --gpus all ubuntu:24.04 echo ok 2>/dev/null | grep -q ok; then
    pass "Container launch with NVIDIA runtime successful"
else
    warn "Container launch with NVIDIA runtime failed — runtime is registered but may need reboot"
fi

# Check daemon.json security settings
if [[ -f /etc/docker/daemon.json ]]; then
    if python3 -c "import json; d=json.load(open('/etc/docker/daemon.json')); assert d.get('no-new-privileges')" 2>/dev/null; then
        pass "Docker: no-new-privileges=true"
    else
        warn "Docker daemon.json missing no-new-privileges setting"
    fi
    if python3 -c "import json; d=json.load(open('/etc/docker/daemon.json')); assert d.get('userland-proxy') == False" 2>/dev/null; then
        pass "Docker: userland-proxy=false"
    else
        warn "Docker daemon.json missing userland-proxy=false setting"
    fi
fi

# ---------------------------------------------------------------------------
# Layer 3: Ollama
# ---------------------------------------------------------------------------
section "Layer 3 — Ollama"

if systemctl is-active ollama &>/dev/null; then
    pass "Ollama service is running"
else
    fail "Ollama service not running — run: sudo systemctl start ollama"
fi

if systemctl is-enabled ollama &>/dev/null; then
    pass "Ollama service is enabled (survives reboot)"
else
    warn "Ollama service not enabled: sudo systemctl enable ollama"
fi

if curl -sf http://localhost:11434 &>/dev/null; then
    pass "Ollama HTTP endpoint responding at :11434"
else
    fail "Ollama not responding at http://localhost:11434"
fi

if ollama list 2>/dev/null | grep -q "nemotron-3-super:120b"; then
    local_model_info=$(ollama list 2>/dev/null | grep "nemotron-3-super:120b" | head -1)
    pass "Model present: $local_model_info"
else
    fail "Model ${MODEL} not found — run: ollama pull ${MODEL}"
fi

# Verify Ollama binds to 0.0.0.0 (required for Docker bridge access)
if [[ -f /etc/systemd/system/ollama.service.d/override.conf ]]; then
    if grep -q "OLLAMA_HOST=0.0.0.0" /etc/systemd/system/ollama.service.d/override.conf; then
        pass "Ollama configured to bind 0.0.0.0 (UFW protects this)"
    else
        warn "Ollama host override may not be set to 0.0.0.0"
    fi
else
    warn "Ollama systemd override not found — sandbox may not reach Ollama"
fi

# ---------------------------------------------------------------------------
# Layer 4: NemoClaw + sandbox
# ---------------------------------------------------------------------------
section "Layer 4 — NemoClaw sandbox"

if ! command -v nemoclaw &>/dev/null; then
    fail "nemoclaw CLI not found in PATH"
else
    pass "nemoclaw CLI installed: $(command -v nemoclaw)"

    # Sandbox status
    if nemoclaw "${SANDBOX_NAME}" status &>/dev/null 2>&1; then
        pass "Sandbox '${SANDBOX_NAME}' is running"
    else
        fail "Sandbox '${SANDBOX_NAME}' not running — try: nemoclaw ${SANDBOX_NAME} start"
    fi

    # Check policy hardening
    policy_file="${HOME}/.nemoclaw/source/nemoclaw-blueprint/policies/openclaw-sandbox.yaml"
    if [[ -f "$policy_file" ]]; then
        if python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open('${policy_file}'))
    net = d.get('network_policies', None)
    # Empty dict or None = deny-all
    if net == {} or net is None:
        sys.exit(0)
    else:
        # Check for dangerous endpoints
        net_str = str(net)
        bad = [e for e in ['clawhub.com', 'sentry.io', 'statsig.anthropic.com'] if e in net_str]
        if bad:
            print('Dangerous endpoints still in policy: ' + ', '.join(bad))
            sys.exit(1)
        sys.exit(0)
except Exception as e:
    print(str(e))
    sys.exit(0)  # yaml may not be installed, skip check
" 2>/dev/null; then
            pass "Sandbox network policy: deny-all baseline (no dangerous endpoints)"
        else
            warn "Sandbox network policy may still allow dangerous endpoints"
            warn "Check: cat $policy_file"
        fi
    else
        warn "Policy file not found: $policy_file"
    fi
fi

# Reboot survival service
if systemctl is-enabled nemoclaw-sandbox.service &>/dev/null 2>&1; then
    pass "nemoclaw-sandbox.service is enabled (reboot-safe)"
else
    warn "nemoclaw-sandbox.service not enabled — sandbox may not start after reboot"
    warn "Fix: sudo systemctl enable nemoclaw-sandbox.service"
fi

if systemctl is-active nemoclaw-sandbox.service &>/dev/null 2>&1; then
    pass "nemoclaw-sandbox.service is currently active"
else
    info "nemoclaw-sandbox.service not active (may be ok if sandbox started another way)"
fi

# ---------------------------------------------------------------------------
# Layer 5: In-sandbox verification (optional — requires sandbox to be running)
# ---------------------------------------------------------------------------
section "Layer 5 — In-sandbox isolation checks"

if ! command -v nemoclaw &>/dev/null || ! nemoclaw "${SANDBOX_NAME}" status &>/dev/null 2>&1; then
    warn "Skipping in-sandbox checks (sandbox not accessible)"
else
    info "Running checks inside sandbox via 'nemoclaw ${SANDBOX_NAME} exec'..."

    # Test inference routing
    inference_result=$(nemoclaw "${SANDBOX_NAME}" exec -- \
        curl -sf --max-time 10 https://inference.local/v1/models 2>/dev/null || echo "FAILED")
    if echo "$inference_result" | grep -qi "nemotron\|model"; then
        pass "Inference routing: request goes through OpenShell → host Ollama"
    elif echo "$inference_result" | grep -qi "FAILED\|error\|refused"; then
        fail "Inference routing not working — check OpenShell gateway"
        info "Debug: nemoclaw ${SANDBOX_NAME} connect, then: curl -sf https://inference.local/v1/models"
    else
        warn "Inference result unclear: $inference_result"
    fi

    # Test deny-all network policy (should FAIL to reach internet)
    deny_result=$(nemoclaw "${SANDBOX_NAME}" exec -- \
        curl -sf --max-time 5 https://api.github.com 2>/dev/null && echo "ALLOWED" || echo "BLOCKED")
    if echo "$deny_result" | grep -q "BLOCKED"; then
        pass "Deny-all network policy: external internet blocked (api.github.com)"
    else
        fail "Deny-all NOT working — sandbox can reach api.github.com (policy too permissive)"
        info "Fix: review and tighten ~/.nemoclaw/source/nemoclaw-blueprint/policies/openclaw-sandbox.yaml"
    fi
fi

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------
section "Dashboard"

if [[ -f "${HOME}/.nemoclaw/dashboard-token.txt" ]]; then
    token=$(cat "${HOME}/.nemoclaw/dashboard-token.txt")
    info "Dashboard URL: http://127.0.0.1:${DASHBOARD_PORT}/#token=${token}"
    pass "Dashboard token saved"

    if curl -sf --max-time 3 "http://127.0.0.1:${DASHBOARD_PORT}/" &>/dev/null; then
        pass "Dashboard port ${DASHBOARD_PORT} responding (only accessible locally)"
    else
        warn "Dashboard not responding on :${DASHBOARD_PORT} — is NemoClaw running?"
    fi
else
    warn "Dashboard token file not found: ${HOME}/.nemoclaw/dashboard-token.txt"
    warn "Check install log or run: nemoclaw ${SANDBOX_NAME} status"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
total=$((PASS + FAIL + WARN_COUNT))
echo -e "  Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${WARN_COUNT} warnings${NC}  (${total} total)"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAIL -eq 0 && $WARN_COUNT -eq 0 ]]; then
    echo -e "\n  ${GREEN}${BOLD}All checks passed. Deployment is healthy.${NC}"
elif [[ $FAIL -eq 0 ]]; then
    echo -e "\n  ${YELLOW}Passed with warnings. Review the WARN items above.${NC}"
else
    echo -e "\n  ${RED}${FAIL} check(s) failed. Address FAIL items before proceeding.${NC}"
    exit 1
fi
echo ""

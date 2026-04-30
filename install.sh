#!/usr/bin/env bash
# =============================================================================
# hardclaw install.sh
# Security-hardened NemoClaw + Ollama + Nemotron 3 Super 120B on Dell Pro Max GB10
# Based on: nemoclaw-hardened-ollama-gb10.md
#
# Usage: bash install.sh [--sandbox-name NAME] [--tag TAG] [--model MODEL]
#
# Reboot-safe: run once. Takes ~15–30 min (dominated by 87 GB model pull).
# Idempotent: safe to re-run if interrupted.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env vars or CLI flags)
# ---------------------------------------------------------------------------
SANDBOX_NAME="${HARDCLAW_SANDBOX_NAME:-my-assistant}"
NEMOCLAW_TAG="${HARDCLAW_NEMOCLAW_TAG:-v0.0.4}"
MODEL="${HARDCLAW_MODEL:-nemotron-3-super:120b}"
DASHBOARD_PORT=18789
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/hardclaw-install.log"
TOKEN_FILE="${HOME}/.nemoclaw/dashboard-token.txt"
SUMMARY_FILE="${HOME}/.nemoclaw/install-summary.txt"

# Parse CLI flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sandbox-name) SANDBOX_NAME="$2"; shift 2 ;;
        --tag)          NEMOCLAW_TAG="$2"; shift 2 ;;
        --model)        MODEL="$2"; shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Logging + color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; BOLD='\033[1m'; NC='\033[0m'

_log() { echo -e "$*" | tee -a "$LOG_FILE"; }
info()  { _log "${BLUE}[hardclaw]${NC} $*"; }
ok()    { _log "  ${GREEN}✓${NC} $*"; }
warn()  { _log "  ${YELLOW}!${NC} $*"; }
die()   { _log "  ${RED}✗ ERROR:${NC} $*"; exit 1; }
step()  { _log "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ---------------------------------------------------------------------------
# Phase 0 — Preflight checks
# ---------------------------------------------------------------------------
phase_preflight() {
    step "Phase 0 — Preflight checks"

    # OS check
    local os_id os_ver
    os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2)
    os_ver=$(grep '^VERSION_ID=' /etc/os-release | tr -d '"' | cut -d= -f2)
    if [[ "$os_id" != "ubuntu" || "$os_ver" != "24.04" ]]; then
        warn "Expected Ubuntu 24.04 but found: $os_id $os_ver. Continuing anyway."
    else
        ok "OS: Ubuntu 24.04"
    fi

    # GPU check
    if ! nvidia-smi &>/dev/null; then
        die "nvidia-smi failed. Is the NVIDIA driver installed?"
    fi
    local gpu_name
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    ok "GPU: $gpu_name"

    # Docker check
    if ! docker info &>/dev/null; then
        die "Docker is not running. Start it with: sudo systemctl start docker"
    fi
    local docker_ver
    docker_ver=$(docker info --format '{{.ServerVersion}}' 2>/dev/null)
    ok "Docker: $docker_ver"

    # sudo check
    if ! sudo -n true 2>/dev/null; then
        info "This script requires sudo access. You may be prompted for your password."
        sudo true || die "sudo access required. Add your user to sudoers."
    fi
    ok "sudo: available"

    # Memory check
    local free_gb
    free_gb=$(awk '/^MemAvailable:/{printf "%d", $2/1024/1024}' /proc/meminfo)
    if [[ "$free_gb" -lt 90 ]]; then
        warn "Only ${free_gb} GB free RAM. The model needs ~87 GB. Flush caches if needed:"
        warn "  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'"
    else
        ok "Memory: ${free_gb} GB available"
    fi

    # Disk space check (model needs ~90 GB)
    local free_disk_gb
    free_disk_gb=$(df -BG /home | awk 'NR==2{gsub("G","",$4); print $4}')
    if [[ "$free_disk_gb" -lt 90 ]]; then
        warn "Only ${free_disk_gb} GB free on /home. Model download needs ~90 GB."
        warn "Free up space before continuing."
        read -rp "  Continue anyway? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    else
        ok "Disk: ${free_disk_gb} GB free"
    fi

    # Back up existing ~/.nemoclaw if present
    if [[ -d "${HOME}/.nemoclaw" ]]; then
        local bak="${HOME}/.nemoclaw.bak.$(date +%Y%m%d_%H%M%S)"
        warn "Backing up existing ~/.nemoclaw to $bak"
        cp -a "${HOME}/.nemoclaw" "$bak"
    fi

    info "Estimated total time: 15–30 minutes (dominated by ${MODEL} download)"
    info "Log file: $LOG_FILE"
}

# ---------------------------------------------------------------------------
# Phase 1 — Host hardening (UFW + avahi)
# ---------------------------------------------------------------------------
phase_harden_host() {
    step "Phase 1 — Host hardening"

    # Install UFW
    if ! command -v ufw &>/dev/null; then
        info "Installing UFW..."
        sudo apt-get install -y ufw
    fi
    ok "UFW installed"

    # Detect LAN subnet from default route
    local gateway lan_subnet
    gateway=$(ip route | awk '/^default/{print $3; exit}')
    if [[ -z "$gateway" ]]; then
        warn "Could not detect default gateway. Defaulting to 192.168.1.0/24 for SSH."
        lan_subnet="192.168.1.0/24"
    else
        lan_subnet=$(echo "$gateway" | awk -F. '{print $1"."$2"."$3".0/24"}')
    fi
    info "Detected LAN subnet: $lan_subnet"

    # Reset and reconfigure UFW (--force avoids confirmation prompts)
    sudo ufw --force reset

    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    # SSH from LAN only
    sudo ufw allow from "$lan_subnet" to any port 22 proto tcp comment 'SSH from LAN'

    # Block dashboard port from network
    sudo ufw deny "$DASHBOARD_PORT" comment 'Block OpenShell dashboard from network'

    # Allow Docker bridges to reach Ollama
    sudo ufw allow from 172.17.0.0/16 to any port 11434 proto tcp comment 'Docker bridge to Ollama'
    sudo ufw allow from 172.18.0.0/16 to any port 11434 proto tcp comment 'OpenShell cluster to Ollama'

    # Also allow common k3s/OpenShell subnets
    sudo ufw allow from 10.42.0.0/16 to any port 11434 proto tcp comment 'k3s pod network to Ollama'

    sudo ufw --force enable
    ok "UFW enabled with deny-all baseline"
    sudo ufw status verbose | grep -v "^$" | tee -a "$LOG_FILE"

    # Disable avahi (prevents mDNS broadcasting)
    if systemctl is-active avahi-daemon &>/dev/null; then
        sudo systemctl disable --now avahi-daemon
        ok "avahi-daemon disabled"
    else
        ok "avahi-daemon already inactive"
    fi
}

# ---------------------------------------------------------------------------
# Phase 2 — Docker + NVIDIA runtime hardening
# ---------------------------------------------------------------------------
phase_docker() {
    step "Phase 2 — Docker + NVIDIA runtime"

    # Configure NVIDIA container runtime
    info "Configuring NVIDIA container runtime..."
    sudo nvidia-ctk runtime configure --runtime=docker
    ok "NVIDIA runtime configured"

    # Merge hardened settings into daemon.json
    info "Hardening Docker daemon.json..."
    sudo python3 -c "
import json, os
path = '/etc/docker/daemon.json'
d = json.load(open(path)) if os.path.exists(path) else {}
d.update({
    'default-runtime': 'nvidia',
    'default-cgroupns-mode': 'host',
    'no-new-privileges': True,
    'userland-proxy': False,
    'live-restore': True,
    'log-driver': 'json-file',
    'log-opts': {'max-size': '10m', 'max-file': '5'}
})
json.dump(d, open(path, 'w'), indent=2)
print('daemon.json updated')
"
    ok "daemon.json hardened"

    # Restart Docker
    info "Restarting Docker..."
    sudo systemctl restart docker
    sleep 3

    # Verify NVIDIA runtime is registered (GB10/ARM64 doesn't mount nvidia-smi into
    # generic containers, so we check docker info rather than running nvidia-smi inside)
    info "Verifying NVIDIA runtime via docker info..."
    if docker info 2>/dev/null | grep -q "nvidia"; then
        ok "NVIDIA runtime registered: $(docker info 2>/dev/null | grep 'Default Runtime')"
    else
        die "NVIDIA runtime not found in docker info. Try: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
    fi

    # Smoke-test: container can start with the NVIDIA runtime
    info "Smoke-testing container launch with NVIDIA runtime..."
    if docker run --rm --runtime=nvidia --gpus all ubuntu:24.04 echo "NVIDIA runtime OK" 2>/dev/null; then
        ok "Container launched successfully with NVIDIA runtime"
    else
        warn "Container smoke-test failed — runtime is registered but may need a reboot to activate fully."
        warn "Continue with the install; reboot if issues persist."
    fi
}

# ---------------------------------------------------------------------------
# Phase 3 — Ollama install + configure
# ---------------------------------------------------------------------------
phase_ollama() {
    step "Phase 3 — Ollama"

    if command -v ollama &>/dev/null; then
        ok "Ollama already installed: $(ollama --version 2>/dev/null || echo 'version unknown')"
    else
        info "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        ok "Ollama installed"
    fi

    # Configure to listen on all interfaces (UFW restricts access)
    info "Configuring Ollama to bind 0.0.0.0 (required for Docker bridge access)..."
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\n' | \
        sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null
    ok "Ollama override.conf written"

    sudo systemctl daemon-reload
    sudo systemctl enable ollama
    sudo systemctl restart ollama

    # Wait for Ollama to be ready (up to 30 seconds)
    info "Waiting for Ollama to start..."
    local attempts=0
    until curl -sf http://localhost:11434 &>/dev/null; do
        sleep 2
        attempts=$((attempts + 1))
        [[ $attempts -gt 15 ]] && die "Ollama did not start in 30 seconds. Check: journalctl -u ollama"
    done
    ok "Ollama is running at http://localhost:11434"
}

# ---------------------------------------------------------------------------
# Phase 4 — Pull Nemotron 3 Super 120B
# ---------------------------------------------------------------------------
phase_model_pull() {
    step "Phase 4 — Model pull (${MODEL})"

    if ollama list 2>/dev/null | grep -q "nemotron-3-super:120b"; then
        ok "Model ${MODEL} already present — skipping download"
    else
        info "Pulling ${MODEL} (~87 GB). This will take 15–30 minutes..."
        info "You can safely leave this running. Progress is shown below."
        ollama pull "$MODEL"
        ok "Model pull complete"
    fi

    # Pre-warm into UMA (Unified Memory Architecture)
    info "Pre-warming model into memory (type /bye to exit if it prompts)..."
    printf '/bye\n' | timeout 120 ollama run "$MODEL" &>/dev/null || true
    ok "Model pre-warmed"

    # Verify
    if ollama list | grep -q "nemotron-3-super:120b"; then
        ok "Model verified: $(ollama list | grep nemotron-3-super:120b)"
    else
        die "Model not listed after pull. Try: ollama list"
    fi
}

# ---------------------------------------------------------------------------
# Phase 5 — NemoClaw install
# ---------------------------------------------------------------------------
phase_nemoclaw_install() {
    step "Phase 5 — NemoClaw install (tag: ${NEMOCLAW_TAG})"

    if command -v nemoclaw &>/dev/null; then
        local current_ver
        current_ver=$(nemoclaw --version 2>/dev/null || echo "unknown")
        warn "NemoClaw already installed (version: $current_ver)."
        warn "If you want a fresh install, uninstall first:"
        warn "  cd ~/.nemoclaw/source && ./uninstall.sh --yes"
        warn "Continuing with existing install..."
        return 0
    fi

    info "Installing NemoClaw ${NEMOCLAW_TAG}..."
    curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_INSTALL_TAG="${NEMOCLAW_TAG}" bash

    # Refresh PATH — try every plausible location the NVIDIA installer might use
    hash -r 2>/dev/null || true

    # 1. Common explicit paths (including npm-global which NVIDIA's installer uses)
    export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/usr/bin:$PATH"

    # 2. Re-source shell profile (installer may have added to PATH there)
    # shellcheck disable=SC1090
    for rc in "${HOME}/.bashrc" "${HOME}/.profile" "${HOME}/.bash_profile"; do
        [[ -f "$rc" ]] && source "$rc" 2>/dev/null || true
    done
    hash -r 2>/dev/null || true

    # 3. npm global bin (npm bin -g removed in npm v9+; derive from prefix instead)
    if ! command -v nemoclaw &>/dev/null; then
        local npm_bin npm_prefix
        npm_prefix=$(npm config get prefix 2>/dev/null || echo "")
        if [[ -n "$npm_prefix" ]]; then
            npm_bin="${npm_prefix}/bin"
            [[ -d "$npm_bin" ]] && export PATH="${npm_bin}:$PATH"
        fi
    fi

    # 4. nvm-managed node
    if ! command -v nemoclaw &>/dev/null && [[ -d "${HOME}/.nvm" ]]; then
        # shellcheck disable=SC1090
        source "${HOME}/.nvm/nvm.sh" 2>/dev/null || true
        local nvm_bin
        nvm_bin=$(nvm which current 2>/dev/null | xargs dirname 2>/dev/null || echo "")
        [[ -n "$nvm_bin" ]] && export PATH="${nvm_bin}:$PATH"
    fi

    # 5. Exhaustive filesystem search (last resort — caps at 5 seconds)
    if ! command -v nemoclaw &>/dev/null; then
        local found
        found=$(timeout 5 find /usr /home/"$(whoami)" /opt /snap \
            -maxdepth 8 -name nemoclaw -type f -perm /111 2>/dev/null | head -1 || true)
        if [[ -n "$found" ]]; then
            export PATH="$(dirname "$found"):$PATH"
            info "Found nemoclaw via filesystem search: $found"
        fi
    fi

    if ! command -v nemoclaw &>/dev/null; then
        die "nemoclaw not found in PATH after install. Locations searched: ~/.local/bin, npm global, nvm, /usr, /opt, /snap. Check the installer output above for errors."
    fi

    ok "NemoClaw installed: $(nemoclaw --version 2>/dev/null || echo 'version unknown')"

    # Show available commands to help with systemd service later
    NEMOCLAW_BIN=$(command -v nemoclaw)
    info "NemoClaw binary: $NEMOCLAW_BIN"
    nemoclaw --help 2>/dev/null | tee -a "$LOG_FILE" || true
}

# ---------------------------------------------------------------------------
# Phase 6 — Sandbox onboard (automated via expect)
# ---------------------------------------------------------------------------

# Write the expect script to a temp file and run it
_run_onboard_expect() {
    local log="$1"

    # Install expect if needed
    if ! command -v expect &>/dev/null; then
        sudo apt-get install -y expect
    fi

    info "Starting nemoclaw onboard wizard (automated)..."
    info "If automation fails, you will be prompted to complete it manually."

    local expect_log
    expect_log=$(mktemp /tmp/hardclaw-onboard-XXXXXX.log)

    # Run expect in a subshell so we can capture output
    expect -c "
        set timeout 300
        log_file \"$expect_log\"
        log_user 1

        spawn nemoclaw onboard
        set spawned_pid [exp_pid]

        # Track state to avoid duplicate sends
        set name_sent 0
        set provider_sent 0
        set model_sent 0
        set policy_sent 0

        expect {
            # Sandbox name prompt
            -re {[Ss]andbox.*[Nn]ame|[Nn]ame.*sandbox|Enter.*name} {
                if {\$name_sent == 0} {
                    sleep 0.3
                    send \"${SANDBOX_NAME}\r\"
                    set name_sent 1
                }
                exp_continue
            }

            # Inference provider selection (numbered list)
            # The guide indicates Local Ollama is option 7
            -re {[Ss]elect.*provider|inference.*provider|[Pp]rovider.*\[} {
                if {\$provider_sent == 0} {
                    sleep 0.5
                    send \"7\r\"
                    set provider_sent 1
                }
                exp_continue
            }

            # If we see the Ollama option explicitly listed
            -re {[Ll]ocal [Oo]llama} {
                if {\$provider_sent == 0} {
                    sleep 0.3
                    send \"7\r\"
                    set provider_sent 1
                }
                exp_continue
            }

            # Model selection
            -re {[Ss]elect.*model|[Ww]hich model|[Mm]odel.*\[|[Ee]nter.*model} {
                if {\$model_sent == 0} {
                    sleep 0.5
                    send \"1\r\"
                    set model_sent 1
                }
                exp_continue
            }

            # Policy presets
            -re {[Pp]olicy|[Pp]reset|[Aa]dd.*polic} {
                if {\$policy_sent == 0} {
                    sleep 0.3
                    send \"Y\r\"
                    set policy_sent 1
                }
                exp_continue
            }

            # Generic Y/N prompts — accept defaults
            -re {\[Y/n\]|\[y/N\]|\(Y/n\)|\(y/N\)} {
                sleep 0.2
                send \"Y\r\"
                exp_continue
            }

            # Press enter to continue
            -re {[Pp]ress.*[Ee]nter|continue.*\\.\\.\\.} {
                sleep 0.2
                send \"\r\"
                exp_continue
            }

            # Dashboard URL — capture it
            -re {127\\.0\\.0\\.1:${DASHBOARD_PORT}/#token=} {
                exp_continue
            }

            eof {
                # Wizard completed
            }

            timeout {
                puts \"\\nWizard timed out. Falling back to manual mode.\"
                exit 1
            }
        }
    " 2>&1 | tee -a "$log" || {
        warn "Automated wizard failed or timed out."
        warn "Please complete the onboard wizard manually:"
        warn "  nemoclaw onboard"
        warn "Use these answers:"
        warn "    Sandbox name:       ${SANDBOX_NAME}"
        warn "    Inference provider: Local Ollama (option 7)"
        warn "    Model:              ${MODEL} (option 1)"
        warn "    Policy presets:     Y (accept defaults)"
        warn ""
        warn "After the wizard completes, run this script again to continue."
        exit 1
    }

    cat "$expect_log" >> "$log"
    rm -f "$expect_log"
}

phase_onboard() {
    step "Phase 6 — Sandbox onboard"

    # Check if sandbox already exists
    if nemoclaw "${SANDBOX_NAME}" status &>/dev/null 2>&1; then
        ok "Sandbox '${SANDBOX_NAME}' already exists. Skipping initial onboard."
        return 0
    fi

    _run_onboard_expect "$LOG_FILE"

    # Extract dashboard token from log
    local token
    token=$(grep -oP '(?<=#token=)[^\s\r\n"]+' "$LOG_FILE" | tail -1 || true)

    if [[ -n "$token" ]]; then
        mkdir -p "$(dirname "$TOKEN_FILE")"
        echo "$token" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        ok "Dashboard token saved to $TOKEN_FILE"
    else
        warn "Could not auto-capture dashboard token from wizard output."
        warn "Check the log at $LOG_FILE for the token, or run: nemoclaw ${SANDBOX_NAME} status"
    fi

    # Verify sandbox started
    sleep 5
    if nemoclaw "${SANDBOX_NAME}" status &>/dev/null 2>&1; then
        ok "Sandbox '${SANDBOX_NAME}' is running"
    else
        warn "Sandbox status check failed — it may still be starting up."
    fi
}

# ---------------------------------------------------------------------------
# Phase 7 — Policy hardening (deny-all network baseline)
# ---------------------------------------------------------------------------
phase_policy_harden() {
    step "Phase 7 — Sandbox policy hardening"

    # Find the policy file
    local policy_dir="${HOME}/.nemoclaw/source/nemoclaw-blueprint/policies"
    local policy_file="${policy_dir}/openclaw-sandbox.yaml"

    if [[ ! -d "$policy_dir" ]]; then
        die "Policy directory not found: $policy_dir\nDid the onboard step complete successfully?"
    fi

    # Show current policy
    info "Current policy:"
    cat "$policy_file" | tee -a "$LOG_FILE" || true

    # Write hardened policy (deny-all network baseline)
    info "Writing hardened policy (deny-all network baseline)..."
    cat > "$policy_file" <<'YAML'
version: 1

filesystem_policy:
  include_workdir: true
  read_only:
    - /usr
    - /lib
    - /proc
    - /dev/urandom
    - /app
    - /etc
    - /var/log
  read_write:
    - /sandbox
    - /tmp
    - /dev/null

landlock:
  compatibility: best_effort

process:
  run_as_user: sandbox
  run_as_group: sandbox

network_policies: {}
# Deny-all network baseline.
# Inference routes via OpenShell gateway to host Ollama — no direct
# sandbox egress is needed. Removed endpoints:
#   clawhub.com            (12% malicious packages, Q1 2026)
#   api.anthropic.com      (not needed with local Ollama)
#   integrate.api.nvidia.com (not needed with local Ollama)
#   sentry.io              (telemetry, unnecessary data egress)
#   statsig.anthropic.com  (telemetry, unnecessary data egress)
YAML
    ok "Hardened policy written"

    # Destroy the sandbox (locks policy at creation time, must recreate)
    info "Destroying sandbox to re-apply policy (this is required — not destructive to data)..."
    nemoclaw "${SANDBOX_NAME}" destroy || true

    # Recreate with hardened policy
    info "Recreating sandbox with hardened policy..."
    _run_onboard_expect "$LOG_FILE"

    # Re-capture token (it may change on recreate)
    local token
    token=$(grep -oP '(?<=#token=)[^\s\r\n"]+' "$LOG_FILE" | tail -1 || true)
    if [[ -n "$token" ]]; then
        echo "$token" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        ok "Dashboard token updated: $TOKEN_FILE"
    fi

    ok "Sandbox policy hardened and sandbox recreated"
}

# ---------------------------------------------------------------------------
# Phase 8 — Reboot survival (systemd service + startup wrapper)
# ---------------------------------------------------------------------------
phase_systemd() {
    step "Phase 8 — Reboot survival"

    local nemoclaw_bin username home_dir
    nemoclaw_bin=$(command -v nemoclaw)
    username=$(whoami)
    home_dir="$HOME"

    # Ensure the OpenShell cluster container has a restart policy so Docker
    # brings it back on reboot (it's already set to unless-stopped, but be safe)
    local openshell_container
    openshell_container=$(docker ps -aq --filter "name=openshell" 2>/dev/null | head -1 || true)
    if [[ -n "$openshell_container" ]]; then
        docker update --restart=unless-stopped "$openshell_container" &>/dev/null && \
            ok "OpenShell container: restart=unless-stopped confirmed" || true
    fi

    # ------------------------------------------------------------------
    # Startup wrapper: waits for dependencies, then brings up the stack
    # ------------------------------------------------------------------
    sudo tee /usr/local/bin/nemoclaw-sandbox-start > /dev/null <<WRAPPER
#!/usr/bin/env bash
# hardclaw startup wrapper — do not edit manually (managed by install.sh)
set -euo pipefail

export PATH="${home_dir}/.npm-global/bin:${home_dir}/.local/bin:/usr/local/bin:/usr/bin:/bin"
NEMOCLAW="${nemoclaw_bin}"
SANDBOX="${SANDBOX_NAME}"
MODEL="${MODEL}"
LOG=/var/log/nemoclaw-sandbox-start.log

log() { echo "\$(date '+%Y-%m-%d %T') \$*" | tee -a "\$LOG"; }

log "=== nemoclaw-sandbox-start ==="

# 1. Wait for Docker (up to 60 s)
log "Waiting for Docker..."
for i in \$(seq 1 30); do
    docker info &>/dev/null && break
    sleep 2
done
docker info &>/dev/null || { log "ERROR: Docker not ready after 60 s"; exit 1; }
log "Docker ready"

# 2. Wait for OpenShell cluster container (up to 60 s)
log "Waiting for OpenShell container..."
for i in \$(seq 1 30); do
    status=\$(docker inspect openshell-cluster-nemoclaw --format '{{.State.Status}}' 2>/dev/null || echo "missing")
    [[ "\$status" == "running" ]] && break
    if [[ "\$status" == "exited" || "\$status" == "created" ]]; then
        docker start openshell-cluster-nemoclaw &>/dev/null || true
    fi
    sleep 2
done
log "OpenShell container status: \$(docker inspect openshell-cluster-nemoclaw --format '{{.State.Status}}' 2>/dev/null || echo unknown)"

# 3. Wait for Ollama (up to 60 s)
log "Waiting for Ollama..."
for i in \$(seq 1 30); do
    curl -sf http://localhost:11434 &>/dev/null && break
    sleep 2
done
if curl -sf http://localhost:11434 &>/dev/null; then
    log "Ollama ready"
else
    log "WARNING: Ollama not responding — continuing anyway"
fi

# 4. Check if sandbox is already up (k3s inside OpenShell persists across restarts)
if "\$NEMOCLAW" "\$SANDBOX" status &>/dev/null 2>&1; then
    log "Sandbox '\$SANDBOX' already running"
else
    log "Sandbox '\$SANDBOX' not running — running nemoclaw onboard to recreate..."
    # nemoclaw onboard is interactive; pipe in defaults.
    # Adjust option numbers if the wizard layout changes between versions.
    printf '%s\n' "\$SANDBOX" "7" "1" "Y" "" | \
        "\$NEMOCLAW" onboard 2>&1 | tee -a "\$LOG" || \
        log "WARNING: onboard exited non-zero — check \$LOG"
fi

# 5. Start auxiliary services (Telegram bridge, tunnel — no-op if not configured)
"\$NEMOCLAW" start 2>&1 | tee -a "\$LOG" || true

# 6. Pre-warm model into unified memory so first inference is instant
log "Pre-warming \$MODEL into memory..."
printf '/bye\n' | timeout 120 ollama run "\$MODEL" &>/dev/null && \
    log "Model pre-warmed" || \
    log "WARNING: model pre-warm timed out or skipped"

log "=== startup complete ==="
WRAPPER
    sudo chmod +x /usr/local/bin/nemoclaw-sandbox-start

    # ------------------------------------------------------------------
    # Shutdown wrapper: clean, ordered teardown without destroying state
    # ------------------------------------------------------------------
    sudo tee /usr/local/bin/nemoclaw-sandbox-stop > /dev/null <<WRAPPER
#!/usr/bin/env bash
# hardclaw shutdown wrapper — do not edit manually (managed by install.sh)
set -euo pipefail

export PATH="${home_dir}/.npm-global/bin:${home_dir}/.local/bin:/usr/local/bin:/usr/bin:/bin"
NEMOCLAW="${nemoclaw_bin}"
LOG=/var/log/nemoclaw-sandbox-stop.log

log() { echo "\$(date '+%Y-%m-%d %T') \$*" | tee -a "\$LOG"; }

log "=== nemoclaw-sandbox-stop ==="

# 1. Stop auxiliary services (Telegram, tunnel)
log "Stopping auxiliary services..."
"\$NEMOCLAW" stop 2>&1 | tee -a "\$LOG" || true

# 2. Stop OpenShell cluster container (graceful — does NOT trigger unless-stopped restart)
log "Stopping OpenShell container..."
docker stop --time 30 openshell-cluster-nemoclaw 2>&1 | tee -a "\$LOG" || true

log "=== shutdown complete ==="
WRAPPER
    sudo chmod +x /usr/local/bin/nemoclaw-sandbox-stop

    # ------------------------------------------------------------------
    # systemd service unit
    # ------------------------------------------------------------------
    sudo tee /etc/systemd/system/nemoclaw-sandbox.service > /dev/null <<SERVICE
[Unit]
Description=NemoClaw AI Agent Sandbox (${SANDBOX_NAME})
Documentation=file://${SCRIPT_DIR}/nemoclaw-hardened-ollama-gb10.md
After=network-online.target docker.service ollama.service
Requires=docker.service ollama.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${username}
Environment="HOME=${home_dir}"
Environment="PATH=${home_dir}/.npm-global/bin:${home_dir}/.local/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/usr/local/bin/nemoclaw-sandbox-start
ExecStop=/usr/local/bin/nemoclaw-sandbox-stop
TimeoutStartSec=300
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

    sudo systemctl daemon-reload
    sudo systemctl enable nemoclaw-sandbox.service
    ok "nemoclaw-sandbox.service enabled"
    ok "Startup wrapper: /usr/local/bin/nemoclaw-sandbox-start"
    ok "Shutdown wrapper: /usr/local/bin/nemoclaw-sandbox-stop"
    ok "Reboot survival configured"
}

# ---------------------------------------------------------------------------
# Phase 9 — Final verification (quick checks)
# ---------------------------------------------------------------------------
phase_quick_verify() {
    step "Phase 9 — Quick verification"

    local passed=0 failed=0

    _check() {
        local desc="$1"; shift
        if "$@" &>/dev/null 2>&1; then
            ok "$desc"
            passed=$((passed + 1))
        else
            warn "FAILED: $desc"
            failed=$((failed + 1))
        fi
    }

    _check "Docker NVIDIA runtime"    docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
    _check "Ollama responding"        curl -sf http://localhost:11434
    _check "Model present"            ollama list
    _check "UFW active"               sudo ufw status
    _check "Sandbox service enabled"  systemctl is-enabled nemoclaw-sandbox.service

    info "Quick verify: $passed passed, $failed failed"
    [[ $failed -gt 0 ]] && warn "Run ./verify.sh for detailed checks"
}

# ---------------------------------------------------------------------------
# Phase 10 — Summary
# ---------------------------------------------------------------------------
phase_summary() {
    step "Installation Complete"

    # Try to get the dashboard token
    local token=""
    if [[ -f "$TOKEN_FILE" ]]; then
        token=$(cat "$TOKEN_FILE")
    else
        # Try to extract from nemoclaw status output
        token=$(nemoclaw "${SANDBOX_NAME}" status 2>/dev/null | grep -oP '(?<=#token=)[^\s]+' | head -1 || true)
    fi

    # Get this machine's primary IP for SSH tunnel instructions
    local machine_ip
    machine_ip=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{print $7}' || echo "<gb10-ip>")

    local summary
    summary=$(cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║              HARDCLAW INSTALLATION COMPLETE                  ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  Model:   ${MODEL}              ║
║  Sandbox: ${SANDBOX_NAME}                                         ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║  DASHBOARD ACCESS                                            ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  Local (on this machine):                                    ║
║    http://127.0.0.1:${DASHBOARD_PORT}/#token=${token:0:20}...     ║
║                                                              ║
║  Token saved to: ${TOKEN_FILE}   ║
║                                                              ║
║  Remote (SSH tunnel from your laptop):                       ║
║    ssh -L ${DASHBOARD_PORT}:127.0.0.1:${DASHBOARD_PORT} \$(whoami)@${machine_ip}  ║
║    Then open: http://127.0.0.1:${DASHBOARD_PORT}/#token=<token>   ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║  DAILY COMMANDS                                              ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║    nemoclaw ${SANDBOX_NAME} connect       # Shell into sandbox  ║
║    nemoclaw ${SANDBOX_NAME} status        # Health check        ║
║    nemoclaw ${SANDBOX_NAME} logs --follow # Stream logs         ║
║    openshell term                    # Live policy monitor    ║
║    openclaw tui  (inside sandbox)    # Chat with agent        ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║  REBOOT SURVIVAL                                             ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║    systemctl status nemoclaw-sandbox    # Check service       ║
║    journalctl -u nemoclaw-sandbox -f    # View logs           ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║  VERIFICATION                                                ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║    bash ${SCRIPT_DIR}/verify.sh                                      ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

Full install log: ${LOG_FILE}
EOF
)

    echo "$summary" | tee -a "$LOG_FILE"
    echo "$summary" > "$SUMMARY_FILE"
    chmod 600 "$SUMMARY_FILE"

    info "Summary also saved to: $SUMMARY_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "" >> "$LOG_FILE"
    echo "=== hardclaw install started at $(date) ===" >> "$LOG_FILE"
    echo "  SANDBOX_NAME=${SANDBOX_NAME}" >> "$LOG_FILE"
    echo "  NEMOCLAW_TAG=${NEMOCLAW_TAG}" >> "$LOG_FILE"
    echo "  MODEL=${MODEL}" >> "$LOG_FILE"

    _log "\n${BOLD}Hardclaw Installer — Security-Hardened NemoClaw on Dell Pro Max GB10${NC}"
    _log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

    phase_preflight
    phase_harden_host
    phase_docker
    phase_ollama
    phase_model_pull
    phase_nemoclaw_install
    phase_onboard
    phase_policy_harden
    phase_systemd
    phase_quick_verify
    phase_summary
}

main "$@"

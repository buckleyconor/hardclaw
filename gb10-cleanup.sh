#!/usr/bin/env bash
#
# gb10-cleanup.sh
# Returns a Dell Pro Max GB10 to a known-good baseline by removing:
#   1. NemoClaw / OpenClaw / OpenShell (via official uninstaller + sweep)
#   2. NVIDIA NIM container running nemotron-nano-9b-v2 + cached weights
#
# Preserves: NVIDIA driver, CUDA, nvidia-container-toolkit, Docker daemon.
#
# Usage:
#   ./gb10-cleanup.sh             # dry-run, prints what it would do
#   ./gb10-cleanup.sh --apply     # actually execute
#
set -euo pipefail

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

run() {
  if [[ $APPLY -eq 1 ]]; then
    echo "+ $*"
    eval "$@"
  else
    echo "[dry-run] $*"
  fi
}

say() { echo -e "\n=== $* ==="; }

# ---------------------------------------------------------------------------
# 0. Sanity
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)."; exit 1
fi

if [[ $APPLY -eq 0 ]]; then
  echo "DRY-RUN MODE — no changes will be made. Re-run with --apply to execute."
fi

# ---------------------------------------------------------------------------
# 1. NemoClaw / OpenClaw uninstall
# ---------------------------------------------------------------------------
say "NemoClaw / OpenClaw teardown"

# Try the official uninstaller first — adjust path if yours lives elsewhere.
OPENCLAW_DIRS=(
  "/opt/openclaw"
  "/opt/nemoclaw"
  "/usr/local/openclaw"
  "$HOME/openclaw"
)

UNINSTALLER_FOUND=0
for d in "${OPENCLAW_DIRS[@]}"; do
  if [[ -x "$d/uninstall.sh" ]]; then
    run "$d/uninstall.sh --yes"
    UNINSTALLER_FOUND=1
    break
  fi
done

if command -v openclaw-installer >/dev/null 2>&1; then
  run "openclaw-installer uninstall --yes"
  UNINSTALLER_FOUND=1
fi

if [[ $UNINSTALLER_FOUND -eq 0 ]]; then
  echo "WARNING: no OpenClaw uninstaller found. You'll need to point me at the install dir."
  echo "         Skipping policy reversal — DO NOT manually rm AppArmor/seccomp profiles."
fi

# Sweep residual containers/images tagged with nemoclaw or openclaw
run "docker ps -a --filter 'name=nemoclaw' --filter 'name=openclaw' -q | xargs -r docker rm -f"
run "docker images --filter 'reference=*nemoclaw*' --filter 'reference=*openclaw*' -q | xargs -r docker rmi -f"
run "docker volume ls --filter 'name=nemoclaw' --filter 'name=openclaw' -q | xargs -r docker volume rm"

# ---------------------------------------------------------------------------
# 2. Nemotron NIM teardown
# ---------------------------------------------------------------------------
say "Nemotron NIM teardown"

# Stop & remove any container running a nemotron NIM
run "docker ps -a --filter 'ancestor=nvcr.io/nim/nvidia/nemotron-nano-9b-v2' -q | xargs -r docker rm -f"
run "docker ps -a --filter 'name=nemotron' -q | xargs -r docker rm -f"

# Remove the image
run "docker images 'nvcr.io/nim/nvidia/nemotron-nano-9b-v2' -q | xargs -r docker rmi -f"

# Clear NIM model cache (default location — change if you set LOCAL_NIM_CACHE)
NIM_CACHE="${LOCAL_NIM_CACHE:-$HOME/.cache/nim}"
if [[ -d "$NIM_CACHE" ]]; then
  run "rm -rf '$NIM_CACHE'"
else
  echo "No NIM cache at $NIM_CACHE"
fi

# ---------------------------------------------------------------------------
# 3. Generic Docker hygiene (safe — won't touch driver/toolkit)
# ---------------------------------------------------------------------------
say "Docker prune"
run "docker container prune -f"
run "docker image prune -af"
run "docker volume prune -f"
run "docker network prune -f"

# ---------------------------------------------------------------------------
# 4. Verify driver stack is still healthy
# ---------------------------------------------------------------------------
say "Post-cleanup verification"
if [[ $APPLY -eq 1 ]]; then
  nvidia-smi || echo "WARNING: nvidia-smi failed — investigate before next demo."
  docker info >/dev/null && echo "Docker OK"
else
  echo "[dry-run] would run: nvidia-smi && docker info"
fi

say "Done"

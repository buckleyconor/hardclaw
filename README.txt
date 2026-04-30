================================================================================
  HARDCLAW — README
  Security-Hardened NemoClaw + Ollama on Dell Pro Max GB10
================================================================================

This package contains three scripts for deploying, verifying, and shutting down
a security-hardened NemoClaw AI agent sandbox on Dell Pro Max GB10 hardware.

Files:
  install.sh                  — Full installation (run once)
  verify.sh                   — Health checks (run after install or reboot)
  shutdown.sh                 — Clean stack teardown (run when done)
  nemoclaw-hardened-ollama-gb10.md  — Full deployment guide (reference)

Quick start:
  bash install.sh             # ~15–30 min, dominated by 87 GB model download
  bash verify.sh              # confirm all layers are healthy
  bash shutdown.sh            # stop everything cleanly

Environment variables (all optional):
  HARDCLAW_SANDBOX_NAME   Sandbox name (default: my-assistant)
  HARDCLAW_NEMOCLAW_TAG   NemoClaw version to install (default: v0.0.4)
  HARDCLAW_MODEL          Model to pull (default: nemotron-3-super:120b)


================================================================================
  INSTALL.SH — PHASE WALKTHROUGH
================================================================================

---- Phase 0: Preflight Checks ------------------------------------------------

WHAT: Validates the environment before making any changes.
WHY:  Catching problems early (wrong OS, missing GPU, low disk) prevents a
      partially-applied install that is harder to debug and roll back.

Checks:
  - Ubuntu 24.04 confirmed (other versions may behave differently)
  - nvidia-smi succeeds (confirms NVIDIA driver is present)
  - Docker daemon is running (required for OpenShell gateway container)
  - sudo access available (several phases write system files)
  - ≥90 GB free RAM (Nemotron 3 Super 120B needs ~87 GB in unified memory)
  - ≥90 GB free disk on /home (model blobs stored in ~/.ollama)
  - Existing ~/.nemoclaw backed up with a timestamp suffix if present


---- Phase 1: Host Hardening (UFW + avahi) ------------------------------------

WHAT: Configures the host firewall to a deny-all baseline and disables the
      mDNS broadcast daemon.
WHY:  Q1 2026 OpenClaw incidents were caused by exposed ports and unrestricted
      network egress. A deny-all UFW policy means only explicitly permitted
      traffic can enter. avahi-daemon broadcasts the machine's presence on the
      LAN via mDNS — disabled to reduce the attack surface.

Rules applied:
  - Default: deny all incoming, allow all outgoing
  - Allow SSH from the auto-detected LAN subnet only (not from internet)
  - Block port 18789 (NemoClaw dashboard) from the network — SSH tunnel only
  - Allow Docker default bridge (172.17.0.0/16) → Ollama port 11434
  - Allow OpenShell cluster bridge (172.18.0.0/16) → Ollama port 11434
  - Allow k3s pod network (10.42.0.0/16) → Ollama port 11434
    (k3s runs inside the OpenShell container; it needs to reach Ollama)
  - avahi-daemon disabled and masked via systemctl

Why Ollama listens on 0.0.0.0: The Docker/k3s network bridges cannot reach
a process bound to 127.0.0.1. UFW rules restrict which source IPs can
actually reach port 11434, so this is safe.


---- Phase 2: Docker + NVIDIA Runtime Hardening --------------------------------

WHAT: Registers the NVIDIA container runtime with Docker and applies hardened
      daemon settings.
WHY:  NemoClaw's OpenShell gateway runs as a Docker container and must be able
      to pass GPU context to workloads. The hardened daemon settings reduce the
      container escape surface.

nvidia-ctk changes:
  - Registers the NVIDIA runtime so containers can use --runtime=nvidia

daemon.json settings written:
  default-runtime: nvidia       — All containers use the NVIDIA runtime by default
  default-cgroupns-mode: host   — Required for GB10 unified memory visibility
  no-new-privileges: true       — Containers cannot use setuid/setgid to gain
                                  additional privileges (blocks privilege escalation)
  userland-proxy: false         — Disable userland TCP proxy; use kernel iptables
                                  instead (lower attack surface, better performance)
  live-restore: true            — Containers keep running if Docker daemon restarts
                                  (prevents outage during Docker upgrades)
  log-driver: json-file         — Structured log files
  log-opts: max-size 10m/5 files — Prevents disk exhaustion from unbounded logs


---- Phase 3: Ollama Install + Configure ---------------------------------------

WHAT: Installs Ollama (if not present) and configures it as a systemd service
      bound to all interfaces.
WHY:  Ollama is the local inference engine. The model (~87 GB) lives in Ollama's
      model store. The sandbox agent routes all inference calls through the
      OpenShell gateway → host Ollama, so the host must expose port 11434 to
      the Docker/k3s bridge networks (UFW rules added in Phase 1 gate this).

Steps:
  - Installs Ollama via official installer if not already present
  - Writes /etc/systemd/system/ollama.service.d/override.conf setting
    OLLAMA_HOST=0.0.0.0 (so Docker bridges can reach it)
  - Enables and starts the ollama systemd service
  - Waits up to 30 seconds for the HTTP endpoint to become ready


---- Phase 4: Model Pull (Nemotron 3 Super 120B) --------------------------------

WHAT: Downloads the Nemotron 3 Super 120B model into Ollama's model store and
      pre-warms it into unified memory.
WHY:  The GB10's 128 GB unified memory architecture means CPU and GPU share the
      same memory pool — the full 87 GB model fits without quantization trade-offs.
      Pre-warming loads it now so the first inference request is instant rather
      than incurring a cold-load delay at chat time.

Steps:
  - Skipped if the model is already present (idempotent)
  - ollama pull nemotron-3-super:120b (~87 GB, 15–30 min on a fast link)
  - printf '/bye\n' | ollama run ... — loads model into memory, immediately exits


---- Phase 5: NemoClaw Install -------------------------------------------------

WHAT: Installs the NemoClaw CLI (v0.0.4) via NVIDIA's installer script.
WHY:  NemoClaw is the orchestration layer that manages the sandbox lifecycle,
      the OpenShell gateway container, and the k3s cluster inside it. The
      specific version tag (v0.0.4) is pinned to match the tested configuration.

PATH resolution: The NVIDIA installer may place the nemoclaw binary in any of
several locations depending on how Node/npm is set up. The script tries five
resolution strategies in order:
  1. Shell hash refresh + common explicit paths
  2. Source ~/.bashrc / ~/.profile / ~/.bash_profile
  3. npm config get prefix to find npm global bin
  4. nvm-managed Node
  5. filesystem search under /usr, /home, /opt, /snap (5-second cap)


---- Phase 6: Sandbox Onboard --------------------------------------------------

WHAT: Runs the nemoclaw onboard interactive wizard via expect automation to
      create the initial sandbox with local Ollama as the inference provider.
WHY:  The onboard wizard is normally interactive. expect lets the script answer
      the prompts automatically for unattended deployment. If automation fails,
      the script prints the exact answers and exits so you can run the wizard
      manually.

Wizard answers provided:
  Sandbox name:       my-assistant (or HARDCLAW_SANDBOX_NAME)
  Inference provider: Local Ollama (option 7)
  Model:              nemotron-3-super:120b (option 1)
  Policy presets:     Y (accept defaults — hardened in Phase 7)
  All Y/N prompts:    Y (accept defaults)

The dashboard token is captured from the wizard output and saved to
~/.nemoclaw/dashboard-token.txt (chmod 600).


---- Phase 7: Sandbox Policy Hardening -----------------------------------------

WHAT: Overwrites openclaw-sandbox.yaml with a deny-all network policy, then
      destroys and recreates the sandbox so the policy takes effect.
WHY:  Landlock (filesystem) and seccomp (process) policies are locked at sandbox
      creation time — they cannot be changed on a running sandbox. Network policy
      is hot-reloadable, but the initial policy baked in by the wizard may still
      contain dangerous external endpoints from before the Q1 2026 hardening.
      This phase removes all of them.

Endpoints removed (and why):
  clawhub.com                — Third-party package registry; ~12% malicious
                               packages flagged in Q1 2026 incidents
  api.anthropic.com          — Not needed; model is local Ollama, not Anthropic cloud
  integrate.api.nvidia.com   — Not needed; model is local, no NVIDIA cloud calls
  sentry.io                  — Error telemetry; unnecessary data egress
  statsig.anthropic.com      — Feature-flag telemetry; unnecessary data egress

Policy file written: ~/.nemoclaw/source/nemoclaw-blueprint/policies/openclaw-sandbox.yaml

network_policies: {}  — empty dict = deny-all; inference still works because it
                        routes through the OpenShell gateway (not direct egress)

Filesystem policy (Landlock):
  Read-only:  /usr /lib /proc /dev/urandom /app /etc /var/log
  Read-write: /sandbox /tmp /dev/null
  Workdir:    included (agent working directory)

Process policy:
  Runs as user/group "sandbox" (not root)


---- Phase 8: Reboot Survival (systemd) ----------------------------------------

WHAT: Creates a systemd service (nemoclaw-sandbox.service) plus start/stop
      wrapper scripts so the full stack comes up automatically after a reboot.
WHY:  A security-hardened deployment that requires manual intervention after
      every reboot is an operational liability. The service handles the
      dependency chain: network → Docker → Ollama → OpenShell → sandbox.

Files written:
  /usr/local/bin/nemoclaw-sandbox-start   Startup wrapper
  /usr/local/bin/nemoclaw-sandbox-stop    Shutdown wrapper
  /etc/systemd/system/nemoclaw-sandbox.service

Startup sequence (with 60 s timeout at each step):
  1. Wait for Docker daemon
  2. Wait for OpenShell cluster container (starts it if exited)
  3. Wait for Ollama HTTP endpoint
  4. Check if sandbox is already running; if not, run nemoclaw onboard
  5. Start auxiliary services (Telegram bridge, tunnel — no-op if not configured)
  6. Pre-warm model into unified memory

The OpenShell Docker container gets restart=unless-stopped so Docker itself
restarts it on boot; the systemd service handles the sandbox layer above that.


---- Phase 9: Quick Verification -----------------------------------------------

WHAT: Runs five fast checks to confirm the install succeeded.
WHY:  Provides immediate feedback without the full verify.sh depth, so the
      installer can flag obvious problems before printing the summary.

Checks: Docker NVIDIA runtime, Ollama responding, model present,
        UFW active, nemoclaw-sandbox.service enabled.


---- Phase 10: Summary ---------------------------------------------------------

WHAT: Prints the dashboard URL, SSH tunnel command, and daily operation
      commands. Saves the same summary to ~/.nemoclaw/install-summary.txt.


================================================================================
  VERIFY.SH — LAYER-BY-LAYER CHECKS
================================================================================

Run after install or after any reboot to confirm the full stack is healthy.
Exit code 1 if any check fails; 0 if all pass (warnings are non-fatal).

Usage:
  bash verify.sh
  bash verify.sh --sandbox-name my-assistant

---- Layer 1: Host Baseline ---------------------------------------------------

WHAT: Verifies UFW is active, the dashboard port is blocked, Docker→Ollama
      rules are present, and avahi-daemon is disabled.
WHY:  These are the foundational host-level protections. If UFW is off, all
      other security controls can be bypassed from the network.

---- Layer 2: Docker + NVIDIA Runtime -----------------------------------------

WHAT: Confirms Docker is running, NVIDIA runtime is registered, a container
      can launch with --runtime=nvidia, and daemon.json has the hardened flags.
WHY:  If the NVIDIA runtime is not registered, OpenShell (and by extension the
      sandbox) cannot access GPU resources.

---- Layer 3: Ollama -----------------------------------------------------------

WHAT: Checks that the ollama service is running and enabled, the HTTP endpoint
      responds, the model is present, and OLLAMA_HOST=0.0.0.0 is configured.
WHY:  All inference calls from the sandbox route through here. A misconfigured
      binding means the sandbox gets connection-refused errors.

---- Layer 4: NemoClaw Sandbox -------------------------------------------------

WHAT: Confirms nemoclaw CLI is in PATH, the named sandbox is running, the
      policy file exists, and no dangerous endpoints remain in it.
      Also checks that nemoclaw-sandbox.service is enabled and active.
WHY:  The sandbox is the innermost isolation layer. If it is not running or its
      network policy is too permissive, the agent can reach the internet.

---- Layer 5: In-Sandbox Isolation Checks --------------------------------------

WHAT: Executes two tests inside the running sandbox:
  1. Inference test: curl https://inference.local/v1/models must return the
     model list (proves routing through OpenShell → Ollama works)
  2. Deny-all test: curl https://api.github.com must be BLOCKED (proves
     network_policies: {} is actually enforced)
WHY:  These are the ground-truth checks. Everything above can pass and the
      sandbox can still be misconfigured. This layer tests actual behavior.

---- Dashboard -----------------------------------------------------------------

WHAT: Reads the saved token and checks that the dashboard port responds locally.
WHY:  Confirms the UI is available for SSH-tunnel access and reminds you of
      the URL.


================================================================================
  SHUTDOWN.SH — CLEAN TEARDOWN
================================================================================

Stops the stack in reverse dependency order. State is preserved — run
'sudo systemctl start nemoclaw-sandbox' or rerun install.sh to bring
everything back up.

Usage:
  bash shutdown.sh                # stop everything
  bash shutdown.sh --keep-ollama  # leave Ollama running (model stays in memory)
  bash shutdown.sh --sandbox-name NAME

---- Step 1: Stop Auxiliary NemoClaw Services ----------------------------------

WHAT: Calls 'nemoclaw stop' to shut down any optional services (Telegram bridge,
      ngrok/cloudflared tunnel).
WHY:  These must be stopped before the gateway container is torn down, or they
      will lose their network path and may leave stale processes.

---- Step 2: Stop OpenShell Cluster Container ----------------------------------

WHAT: Runs 'docker stop --time 30 openshell-cluster-nemoclaw'.
WHY:  'docker stop' (not 'docker rm') preserves the container state and its
      unless-stopped restart policy. The 30-second grace period lets the k3s
      cluster inside flush any in-flight writes before the container exits.
      Using 'docker stop' instead of 'docker kill' avoids data corruption.

---- Step 3: Stop Ollama -------------------------------------------------------

WHAT: Stops the ollama systemd service, freeing ~87 GB of unified memory.
WHY:  The GB10 has 128 GB total unified memory. Releasing the model frees it for
      other workloads. Skip this step with --keep-ollama if you want inference
      to remain available while the NemoClaw stack is down (e.g., for testing).


================================================================================
  SECURITY NOTES
================================================================================

- Never expose port 18789 (dashboard) directly to the network. Always use an
  SSH tunnel: ssh -L 18789:127.0.0.1:18789 user@<gb10-ip>

- The dashboard token is long-lived. Rotate it by destroying and re-onboarding
  the sandbox: nemoclaw my-assistant destroy && nemoclaw onboard

- If you enable the Telegram bridge, credentials MUST go in a secret store
  (e.g. HashiCorp Vault, systemd Credential, or at minimum a chmod 600 file).
  Do not use plain environment variables in systemd unit files.

- Network policy changes (OpenShell hot-reload) take effect immediately.
  Filesystem and process policy changes require: destroy + onboard.

- After onboard, always run verify.sh Layer 5 (in-sandbox isolation checks)
  to confirm the deny-all network policy is actually enforced.


================================================================================

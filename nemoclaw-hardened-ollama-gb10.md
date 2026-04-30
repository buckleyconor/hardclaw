# Security-Hardened NemoClaw Deployment on Dell Pro Max GB10

**Stack:** NemoClaw + OpenShell + Ollama + Nemotron 3 Super 120B
**Platform:** Dell Pro Max with GB10 (NVIDIA Grace Blackwell, 128 GB unified memory, DGX OS / Ubuntu 24.04)
**Based on:** NVIDIA Spark Playbook (build.nvidia.com/spark/nemoclaw) + NemoClaw GitHub
**Version:** April 2026 — NemoClaw alpha

> **Important:** NemoClaw is alpha / demo software. NVIDIA explicitly states this is provided AS IS for demonstration only — no warranties, not production-ready. Run on a clean environment with no sensitive data.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Pre-Deployment: Host Hardening](#2-pre-deployment-host-hardening)
3. [Phase 1: Docker + NVIDIA Runtime](#3-phase-1-docker--nvidia-runtime)
4. [Phase 2: Hardened Ollama Setup](#4-phase-2-hardened-ollama-setup)
5. [Phase 3: Install NemoClaw with Ollama](#5-phase-3-install-nemoclaw-with-ollama)
6. [Phase 4: Sandbox Policy Hardening](#6-phase-4-sandbox-policy-hardening)
7. [Phase 5: Verify the Sandbox](#7-phase-5-verify-the-sandbox)
8. [Phase 6: Dashboard Access (Hardened)](#8-phase-6-dashboard-access-hardened)
9. [Telegram Bridge: Security Considerations](#9-telegram-bridge-security-considerations)
10. [Monitoring & Operator Approval](#10-monitoring--operator-approval)
11. [Ongoing Maintenance](#11-ongoing-maintenance)
12. [Known Gaps & Limitations](#12-known-gaps--limitations)
13. [Quick Reference](#13-quick-reference)

---

## 1. Architecture Overview

```
Dell Pro Max GB10 (Ubuntu 24.04 / DGX OS, cgroup v2, UMA)
  │
  ├── Ollama service (host)
  │    └── Nemotron 3 Super 120B (local, no cloud egress)
  │
  └── Docker (28.x, cgroupns=host, NVIDIA runtime)
       └── OpenShell gateway container
            └── k3s (embedded)
                 └── NemoClaw sandbox (Landlock + seccomp + netns)
                      └── OpenClaw agent
                           └── Inference → OpenShell gateway → host Ollama
```

**The four isolation layers:**

| Layer | What It Protects | Mutability |
|-------|-----------------|------------|
| **Filesystem** (Landlock LSM) | Prevents reads/writes outside allowed paths | Locked at sandbox creation |
| **Network** (proxy + policy) | Blocks unauthorised outbound connections | Hot-reloadable |
| **Process** (seccomp + namespaces) | Blocks privilege escalation, dangerous syscalls | Locked at sandbox creation |
| **Inference** (gateway routing) | Reroutes model API calls to controlled backend | Hot-reloadable |

**Why Ollama + Nemotron 3 Super 120B is the right choice:**
- The 120B model at ~87 GB fits comfortably in the GB10's 128 GB unified memory
- Ollama is the official NVIDIA Spark playbook recommendation for NemoClaw
- Fully local inference — no API keys in transit, no cloud provider sees prompts
- NVIDIA Agent Toolkit / OpenShell is designed to route inference through the gateway, so even the host Ollama endpoint is never directly reachable from inside the sandbox

---

## 2. Pre-Deployment: Host Hardening

Before touching NemoClaw, lock down the GB10 itself.

### 2.1 Use a Clean Environment

NVIDIA explicitly warns: run this on a fresh device with no personal data, no confidential files, no production credentials. Treat the GB10 like a sandbox for this demo. Do not sign into any work accounts on it while NemoClaw is running.

### 2.2 Update DGX OS

```bash
sudo apt update && sudo apt upgrade -y
sudo reboot
```

### 2.3 Verify System Baseline

```bash
head -n 2 /etc/os-release       # Expect: Ubuntu 24.04
nvidia-smi                       # Expect: NVIDIA GB10 GPU
docker info --format '{{.ServerVersion}}'  # Expect: 28.x or higher
```

### 2.4 Host Firewall (UFW)

This is the single most important host-level control. The #1 reason OpenClaw deployments got compromised in Q1 2026 was exposed gateway ports on the public internet. Lock everything down:

```bash
# Install UFW if not present
sudo apt install -y ufw

# Default deny everything inbound
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH only from your local LAN — adjust subnet as needed
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp comment 'SSH from LAN'

# Block the OpenShell gateway port from anything external
# The dashboard will be accessed via localhost only (or SSH tunnel)
sudo ufw deny 18789 comment 'Block OpenShell gateway from network'

# Allow Ollama on the loopback and Docker bridges ONLY
# (the sandbox reaches Ollama via the Docker bridge, not directly)
sudo ufw allow from 172.17.0.0/16 to any port 11434 proto tcp comment 'Docker bridge to Ollama'
sudo ufw allow from 172.18.0.0/16 to any port 11434 proto tcp comment 'OpenShell cluster to Ollama'

# Enable UFW
sudo ufw enable
sudo ufw status verbose
```

> **Why not bind Ollama to 127.0.0.1 only?** The official NVIDIA instructions explicitly require `OLLAMA_HOST=0.0.0.0` because the sandbox container needs to reach it across the Docker bridge. UFW gives you back the security by blocking everything except the bridge subnets.

### 2.5 Disable mDNS Broadcast

OpenClaw has been known to advertise itself on mDNS (port 5353). Disable that if it's running:

```bash
sudo systemctl disable --now avahi-daemon 2>/dev/null || true
```

### 2.6 Optional: Install Tailscale for Remote Access

If you need to access the GB10 from elsewhere (or want to record the demo from your laptop), use Tailscale instead of exposing SSH or the dashboard to the internet. NVIDIA has their own Spark Tailscale playbook at build.nvidia.com/spark/tailscale, but the short version is:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Then tighten UFW to also allow SSH from the Tailscale subnet (100.64.0.0/10) and remove the LAN-wide SSH rule if you want.

---

## 3. Phase 1: Docker + NVIDIA Runtime

This follows the NVIDIA Spark playbook exactly, with security notes added.

### 3.1 Configure NVIDIA Container Runtime

```bash
sudo nvidia-ctk runtime configure --runtime=docker
```

### 3.2 Set cgroup Namespace Mode

The GB10 runs cgroup v2. OpenShell's embedded k3s fails without `cgroupns=host`:

```bash
sudo python3 -c "
import json, os
path = '/etc/docker/daemon.json'
d = json.load(open(path)) if os.path.exists(path) else {}
d['default-cgroupns-mode'] = 'host'
json.dump(d, open(path, 'w'), indent=2)
"
```

### 3.3 Hardening Add-On: Docker Daemon Security

While you're editing `daemon.json`, add these security flags:

```bash
sudo python3 -c "
import json, os
path = '/etc/docker/daemon.json'
d = json.load(open(path)) if os.path.exists(path) else {}
d['default-cgroupns-mode'] = 'host'
d['no-new-privileges'] = True
d['userland-proxy'] = False
d['live-restore'] = True
d['log-driver'] = 'json-file'
d['log-opts'] = {'max-size': '10m', 'max-file': '5'}
json.dump(d, open(path, 'w'), indent=2)
"
```

What these do:
- `no-new-privileges: true` — prevents containers from gaining privileges via setuid binaries
- `userland-proxy: false` — reduces attack surface, uses iptables directly
- `live-restore: true` — containers keep running during Docker daemon restarts
- `log-opts` — bounded log rotation (prevents disk exhaustion)

### 3.4 Restart Docker and Verify

```bash
sudo systemctl restart docker

# Verify NVIDIA runtime works
docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
```

### 3.5 Docker Group Membership

```bash
sudo usermod -aG docker $USER
newgrp docker  # or log out and back in
```

> **Security note:** Adding a user to the docker group effectively gives them root on the host (they can mount `/` inside a privileged container). Only do this for your own user on this dedicated demo machine. Never do it on a shared system.

---

## 4. Phase 2: Hardened Ollama Setup

### 4.1 Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Verify:

```bash
curl http://localhost:11434
# Expected: "Ollama is running"
```

### 4.2 Configure Ollama to Listen on All Interfaces

This is required for the sandbox to reach it. UFW from Section 2.4 restricts which interfaces can actually connect.

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\n' | \
  sudo tee /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

### 4.3 Verify UFW Is Doing Its Job

From another machine on your LAN, try to reach Ollama:

```bash
# From a different machine — this should FAIL/timeout
curl http://<GB10-ip>:11434
```

If that succeeds, your UFW rules are wrong. Go back to Section 2.4 and fix them. Only the Docker bridge subnets (172.17.0.0/16, 172.18.0.0/16) should be able to reach port 11434.

### 4.4 Pull Nemotron 3 Super 120B

~87 GB download. On a reasonable connection, budget 15–30 minutes.

```bash
ollama pull nemotron-3-super:120b
```

Pre-load into memory (type `/bye` to exit after it responds):

```bash
ollama run nemotron-3-super:120b
```

### 4.5 Verify the Model Is Available

```bash
ollama list
# Should show: nemotron-3-super:120b
```

### 4.6 UMA Memory Tip

The GB10 uses Unified Memory Architecture. If you hit unexpected memory issues even with the 120B model (which should fit), flush the buffer cache:

```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```

---

## 5. Phase 3: Install NemoClaw with Ollama

### 5.1 Security Decision: Pin to a Specific Tag

The NVIDIA playbook uses `NEMOCLAW_INSTALL_TAG=v0.0.4`. Pinning to a specific version means you know exactly which code is running, and you can audit it. Do not use `curl ... | bash` without a pinned tag in a hardened setup.

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_INSTALL_TAG=v0.0.4 bash
```

> **Paranoid option:** Clone the repo at the pinned tag, inspect the installer script, then run it. This adds 5 minutes and lets you actually see what's about to touch your system.
>
> ```bash
> git clone --branch v0.0.4 https://github.com/NVIDIA/NemoClaw.git
> cd NemoClaw
> less install.sh   # Review before running
> sudo npm install -g .
> ```

### 5.2 Onboard Wizard Choices

The wizard will walk you through setup. Use these answers:

| Prompt | Answer |
|--------|--------|
| Sandbox name | `my-assistant` (lowercase alphanumeric with hyphens) |
| Inference provider | **Local Ollama** (option 7) |
| Model | **nemotron-3-super:120b** (option 1) |
| Policy presets | Accept (Y) |

### 5.3 Save the Dashboard Token URL

When the wizard finishes, it prints a tokenised URL that looks like:

```
http://127.0.0.1:18789/#token=<long-token-here>
```

**Save this.** You need it to access the web UI. The token is required — the gateway enforces an exact origin match, so you must use `127.0.0.1` (not `localhost`) and include the `#token=...` hash fragment.

### 5.4 Successful Install Output

You should see:

```
──────────────────────────────────────────────────
Dashboard    http://localhost:18789/
Sandbox      my-assistant (Landlock + seccomp + netns)
Model        nemotron-3-super:120b (Local Ollama)
──────────────────────────────────────────────────
```

The `Landlock + seccomp + netns` tag confirms all three kernel-level enforcement mechanisms are active.

---

## 6. Phase 4: Sandbox Policy Hardening

This is the most important security step. The default policy is reasonable but can be tightened significantly for a hardened demo.

### 6.1 Locate the Policy File

```bash
cd ~/.nemoclaw/source
ls nemoclaw-blueprint/policies/
cat nemoclaw-blueprint/policies/openclaw-sandbox.yaml
```

### 6.2 What the Default Policy Allows

By default, the sandbox has outbound network access to:

- `api.anthropic.com`, `statsig.anthropic.com`, `sentry.io` (for Claude Code)
- `integrate.api.nvidia.com`, `inference-api.nvidia.com` (NVIDIA cloud inference)
- `github.com`, `api.github.com` (for git/gh)
- `clawhub.com` (**REMOVE THIS** — compromised marketplace)
- `openclaw.ai`, `docs.openclaw.ai`
- `registry.npmjs.org`
- `api.telegram.org` (only if you accepted Telegram preset)

### 6.3 Hardened Policy for Ollama-Only Demo

Since you're using local Ollama, you can strip almost all of this. Edit the policy:

```bash
nano nemoclaw-blueprint/policies/openclaw-sandbox.yaml
```

Replace the `network_policies` section with the minimum needed:

```yaml
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

network_policies:
  # EMPTY by default — deny-all baseline.
  # Ollama inference goes through the OpenShell gateway, not via
  # direct sandbox egress, so no network_policies entry is needed
  # for inference.
  #
  # Add back ONLY what your specific demo requires.
  # Do NOT add clawhub, api.anthropic.com, or sentry.io.
```

**Critical removals:**

| Endpoint | Why Remove |
|----------|-----------|
| `clawhub.com` | 12% of ClawHub skills were found malicious in Q1 2026 |
| `api.anthropic.com` | Not needed if using local Ollama |
| `integrate.api.nvidia.com` | Not needed if using local Ollama |
| `sentry.io` | Telemetry — unnecessary data egress |
| `statsig.anthropic.com` | Telemetry — unnecessary data egress |

### 6.4 Re-Apply the Policy

Static fields (filesystem, process, Landlock) are locked at sandbox creation. To apply your changes, you need to destroy and recreate the sandbox:

```bash
# From the host
nemoclaw my-assistant destroy   # or: openshell sandbox delete my-assistant
nemoclaw onboard                 # Re-run wizard with edited policy
```

### 6.5 Verify the Hardened Policy

```bash
openshell policy show
```

Look at the `network_policies` section — it should match what you edited.

---

## 7. Phase 5: Verify the Sandbox

### 7.1 Connect to the Sandbox

```bash
nemoclaw my-assistant connect
```

You should land at `sandbox@my-assistant:~$`.

### 7.2 Verify Inference Routing

Inside the sandbox:

```bash
curl -sf https://inference.local/v1/models
```

Expected: JSON listing `nemotron-3-super:120b`. This confirms that OpenShell is intercepting the inference call and routing it to host Ollama, without the sandbox ever seeing the real Ollama endpoint.

### 7.3 Verify Deny-All Network

Still inside the sandbox, try to reach something that shouldn't be allowed:

```bash
curl -v https://api.github.com
# Expected: HTTP 403 from proxy after CONNECT, or similar
```

If this succeeds, your policy is still too permissive. Check Section 6 again.

### 7.4 Talk to the Agent

```bash
openclaw agent --agent main --local -m "hello" --session-id test
```

Expect a 30–90 second response time — this is a 120B parameter model running locally. Not a bug, just physics.

### 7.5 Interactive TUI (Optional)

```bash
openclaw tui
```

Ctrl+C to exit.

### 7.6 Exit Back to Host

```bash
exit
```

---

## 8. Phase 6: Dashboard Access (Hardened)

The dashboard is a web UI on port 18789. You must never expose this port to the network — OpenClaw's Q1 2026 security disasters were largely caused by exposed dashboard ports.

### 8.1 Local Access (on the GB10 Directly)

If you're on the GB10 with a monitor attached, just open the tokenised URL in a browser:

```
http://127.0.0.1:18789/#token=<your-token>
```

### 8.2 Remote Access via SSH Tunnel (Recommended for Recording)

From the GB10, start the port forward:

```bash
openshell forward start 18789 my-assistant --background
```

From your recording machine, create an SSH tunnel:

```bash
ssh -L 18789:127.0.0.1:18789 <your-user>@<gb10-ip>
```

Then open the tokenised URL on your recording machine:

```
http://127.0.0.1:18789/#token=<your-token>
```

### 8.3 Why Not Expose It Directly?

Don't:

- Bind the dashboard to `0.0.0.0`
- Open port 18789 in UFW
- Put it behind a reverse proxy without authentication
- Share the token URL with anyone

The dashboard gives interactive control over the agent. Anyone with the token URL can drive the agent. Treat it like an SSH key.

---

## 9. Telegram Bridge: Security Considerations

The Telegram bridge is genuinely useful for a demo (you can chat with the agent from your phone), but it adds attack surface. Here's how to think about it.

### 9.1 What the Bridge Does

The bridge is a host-side process that:
1. Polls the Telegram Bot API for new messages
2. Forwards them into the sandboxed agent
3. Returns the agent's response to the user via Telegram

This means the sandbox needs outbound access to `api.telegram.org:443`, and you need a bot token + NVIDIA API key stored on the host.

### 9.2 Security Trade-offs

| Benefit | Risk |
|---------|------|
| Remote access for the demo | Anyone who messages your bot can talk to the agent |
| Clean demo story | Adds a cloud dependency (Telegram) |
| Good video content | Bot token is a credential that must be protected |

### 9.3 If You Enable It, Harden It

**Lock down who can talk to the bot.** By default, anyone who finds your bot's username can message it. Telegram bots support a `allowed_user_ids` whitelist — check whether the NemoClaw bridge honours one, and if so, set it to your own Telegram user ID only.

**Protect the bot token.** Store it in an environment file with `chmod 600`, not in your shell history:

```bash
# Create a protected env file
sudo install -o $USER -g $USER -m 600 /dev/null ~/.nemoclaw.env
cat > ~/.nemoclaw.env <<'EOF'
TELEGRAM_BOT_TOKEN=<your-bot-token>
SANDBOX_NAME=my-assistant
NVIDIA_API_KEY=<your-nvapi-key>
EOF

# Source it when needed
set -a && source ~/.nemoclaw.env && set +a
```

**Revoke immediately after the demo.** Go to @BotFather and use `/revoke` on the bot token the moment you're done recording. Generate a fresh one next time.

**Add only the telegram policy preset, not others:**

```bash
nemoclaw my-assistant policy-add
# When prompted, type: telegram
```

### 9.4 Or: Skip the Bridge Entirely

For a hardened demo focused on the security story, you can skip the Telegram bridge altogether. Just use the TUI and web dashboard. That keeps your egress to zero (except inference) and gives you a cleaner "fully local" narrative.

---

## 10. Monitoring & Operator Approval

This is the feature that makes your demo compelling. Show it on camera.

### 10.1 Open the Monitoring TUI

From the host (not inside the sandbox):

```bash
openshell term
```

This shows:
- Active network connections from the sandbox
- Blocked egress requests awaiting approval
- Inference routing status
- Denied request logs with host, port, and binary

### 10.2 The Operator Approval Flow

When the agent tries to reach something not in the policy:

1. OpenShell blocks the connection
2. The request appears in `openshell term` with host, port, and binary
3. You approve or deny in real time
4. If approved, the endpoint is added to the running policy **for this session only**

This is the single strongest demo moment: ask the agent to fetch something from an unlisted website, show the request being blocked, then approve it live and watch it succeed.

### 10.3 Follow Live Logs

```bash
nemoclaw my-assistant logs --follow
```

Watch for `l7_decision=deny` lines — these are blocked requests. They're your proof that the policy is working.

### 10.4 What to Capture for the Video

1. `openshell term` TUI showing a denied request
2. Approval flow: operator approves, request succeeds
3. Agent response using Nemotron 3 Super 120B locally
4. A side-by-side: raw OpenClaw (all CVEs, wide open) vs NemoClaw (locked down, local inference, deny-all)
5. A clean `nemoclaw my-assistant status` showing the active local-only config

---

## 11. Ongoing Maintenance

### 11.1 Watch the NemoClaw Releases

```bash
# Check current tag
cat ~/.nemoclaw/source/package.json | grep version

# Check for new releases
# https://github.com/NVIDIA/NemoClaw/releases
```

Given the alpha status, expect frequent updates. Read release notes before upgrading.

### 11.2 Update the Pinned Tag

```bash
# Uninstall old version
cd ~/.nemoclaw/source && ./uninstall.sh --yes --keep-openshell

# Reinstall pinned to the new tag
curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_INSTALL_TAG=v0.0.5 bash
```

### 11.3 Review Denied Requests Periodically

```bash
nemoclaw my-assistant logs -n 500 | grep deny
```

A clean deny log means nothing suspicious is happening. A burst of denies means the agent is trying to reach somewhere it shouldn't — investigate before approving.

### 11.4 Rotate Credentials

- Telegram bot token: revoke via @BotFather after every demo
- NVIDIA API key: rotate via build.nvidia.com/settings/api-keys monthly
- SSH keys: standard hygiene

### 11.5 Clean Uninstall When Done

```bash
cd ~/.nemoclaw/source && ./uninstall.sh --yes --delete-models
```

The `--delete-models` flag removes the Ollama 87 GB model too. Omit it if you want to keep it.

---

## 12. Known Gaps & Limitations

Be upfront about these — your audience will respect honesty more than over-selling.

| Limitation | Detail |
|-----------|--------|
| **Alpha software** | Not production-ready. NVIDIA says so in writing. |
| **No MCP tool-level enforcement** | OpenShell controls connections but cannot inspect what tool calls happen inside a permitted TLS tunnel. If you connect MCP servers, this is a real gap. |
| **Single-operator model** | OpenShell is currently single-developer, single-environment. Not a multi-tenant boundary. |
| **Nemotron 3 Super is slow** | 30–90 seconds per response for a 120B model. Budget this into your demo pacing. |
| **UMA memory quirks** | Dell Pro Max GB10 uses UMA; you may hit unexpected memory issues and need to flush buffer cache. |
| **Host compromise = sandbox compromise** | The sandbox protects against agent misbehaviour, not host compromise. If someone gets root on the GB10, NemoClaw cannot help you. |
| **Dashboard token is a credential** | Whoever has the full tokenised URL can drive the agent. Treat it accordingly. |
| **Telegram bridge widens attack surface** | Adds a cloud dependency and a public entry point. Optional. |

---

## 13. Quick Reference

### Install & Setup

```bash
# Docker + NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Ollama + Nemotron
curl -fsSL https://ollama.com/install.sh | sh
ollama pull nemotron-3-super:120b

# NemoClaw (pinned)
curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_INSTALL_TAG=v0.0.4 bash
```

### Daily Use

```bash
nemoclaw my-assistant connect          # Shell into sandbox
nemoclaw my-assistant status           # Health check
nemoclaw my-assistant logs --follow    # Stream logs
openshell term                         # Monitoring TUI
```

### Inside the Sandbox

```bash
openclaw tui                           # Interactive chat
openclaw agent --agent main --local -m "hello" --session-id test
curl -sf https://inference.local/v1/models  # Verify inference
```

### Policy

```bash
openshell policy show                  # View active policy
openshell policy set <file>            # Apply dynamic change
```

### Dashboard (Remote)

```bash
# On GB10:
openshell forward start 18789 my-assistant --background

# On your laptop:
ssh -L 18789:127.0.0.1:18789 user@gb10
# Then browse to: http://127.0.0.1:18789/#token=<token>
```

### Cleanup

```bash
nemoclaw stop                                   # Stop aux services
cd ~/.nemoclaw/source && ./uninstall.sh --yes   # Remove everything
```

---

## Documentation Links

- **NVIDIA Spark Playbook (Overview):** https://build.nvidia.com/spark/nemoclaw/overview
- **NVIDIA Spark Playbook (Instructions):** https://build.nvidia.com/spark/nemoclaw/instructions
- **NVIDIA Spark Playbook (Troubleshooting):** https://build.nvidia.com/spark/nemoclaw/troubleshooting
- **NemoClaw GitHub:** https://github.com/NVIDIA/NemoClaw
- **NemoClaw Docs:** https://docs.nvidia.com/nemoclaw/latest/
- **OpenShell Policy Schema:** https://docs.nvidia.com/openshell/latest/reference/policy-schema.html
- **DGX Spark Docs:** https://docs.nvidia.com/dgx/dgx-spark
- **Tailscale on Spark:** https://build.nvidia.com/spark/tailscale

---

*Guide prepared for Dell Customer Solution Center demo development. Based on the official NVIDIA Spark playbook with additional hardening layers applied. NemoClaw is alpha demo software — verify all steps against the latest docs before running.*

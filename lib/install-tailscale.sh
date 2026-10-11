#!/usr/bin/env bash
# Tailscale remote access and a firewall that leaves model ports closed.

tailscale_logged_in() {
  command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1
}

expose_webui() {
  if tailscale serve --bg http://127.0.0.1:3000; then
    return 0
  fi
  log "Could not enable Tailscale Serve yet. After this node is on your tailnet, run: tailscale serve --bg http://127.0.0.1:3000"
}

install_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  if tailscale_logged_in; then
    tailscale set --ssh || true
    expose_webui
    return 0
  fi
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    tailscale up --ssh --auth-key="$TAILSCALE_AUTHKEY"
    expose_webui
    return 0
  fi
  if [[ -r /dev/tty ]]; then
    log "Log this machine into Tailscale. SSH over Tailscale will be enabled."
    tailscale up --ssh </dev/tty
    expose_webui
    return 0
  fi
  log "Tailscale is installed but not logged in."
  log "Finish with: tailscale up --ssh"
  log "Then expose the UI with: tailscale serve --bg http://127.0.0.1:3000"
}

configure_firewall() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y ufw
  ufw allow OpenSSH
  if [[ -f /etc/ssh/sshd_config ]]; then
    local port
    port="$(awk '/^[[:space:]]*Port[[:space:]]+/ {print $2; exit}' /etc/ssh/sshd_config || true)"
    if [[ -n "${port}" && "${port}" != "22" ]]; then
      ufw allow "${port}/tcp"
    fi
  fi
  ufw allow in on tailscale0
  ufw --force enable
  log "Firewall enabled. OpenSSH and Tailscale are allowed. Ports 3000, 8188, and 11434 are not opened."
}

tailscale_url() {
  if ! tailscale_logged_in; then
    printf '%s\n' ""
    return 0
  fi
  tailscale status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); name=(data.get("Self") or {}).get("DNSName") or ""; name=name.rstrip("."); print("https://"+name if name else "")'
}

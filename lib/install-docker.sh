#!/usr/bin/env bash
# Base packages and Docker Engine from Docker's Ubuntu apt repository.

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg python3 pciutils mokutil openssl ufw lsb-release
}

add_invoking_user_to_docker() {
  if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
    return 0
  fi
  if ! getent group docker >/dev/null 2>&1; then
    return 0
  fi
  if ! id -nG "$SUDO_USER" | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker "$SUDO_USER"
    log "Added ${SUDO_USER} to the docker group. Open a new login before using docker without sudo."
  fi
}

install_docker() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker
    add_invoking_user_to_docker
    state_add docker
    return 0
  fi
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename arch
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  arch="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$arch" "$codename" >/etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  add_invoking_user_to_docker
  state_add docker
}

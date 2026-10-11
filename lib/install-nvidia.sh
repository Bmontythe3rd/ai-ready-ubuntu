#!/usr/bin/env bash
# NVIDIA driver and container toolkit. Exits 20 when a reboot is required.

nvidia_smi_ok() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1
}

hardware_runtime() {
  local hardware_json="$1"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fit"]["runtime"])' "$hardware_json"
}

warn_secure_boot() {
  local hardware_json="$1"
  local sb
  sb="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["secure_boot"])' "$hardware_json")"
  if [[ "$sb" == "enabled" ]]; then
    log "Secure Boot is enabled. The reboot may stop on a MOK enrollment screen. Choose Enroll MOK and enter the password you set, if one is requested."
  fi
}

install_nvidia_toolkit() {
  if state_has nvidia-toolkit && command -v nvidia-ctk >/dev/null 2>&1; then
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  install -m 0755 -d /usr/share/keyrings
  local key_tmp
  key_tmp="$(mktemp)"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o "$key_tmp"
  install -m 0644 "$key_tmp" /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  rm -f "$key_tmp"
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
  state_add nvidia-toolkit
}

install_nvidia() {
  local hardware_json="$1"
  local runtime
  runtime="$(hardware_runtime "$hardware_json")"
  if [[ "$runtime" != "nvidia" ]]; then
    state_add nvidia-skipped
    return 0
  fi
  if nvidia_smi_ok; then
    state_add nvidia-driver
    install_nvidia_toolkit
    return 0
  fi
  if state_has nvidia-driver-packages; then
    warn_secure_boot "$hardware_json"
    log "NVIDIA driver packages are installed, but nvidia-smi is not working yet."
    log "Reboot, then run setup.sh again. It will continue from this point."
    exit 20
  fi
  export DEBIAN_FRONTEND=noninteractive
  warn_secure_boot "$hardware_json"
  apt-get install -y ubuntu-drivers-common
  if ubuntu-drivers install --help >/dev/null 2>&1; then
    ubuntu-drivers install
  else
    ubuntu-drivers autoinstall
  fi
  state_add nvidia-driver-packages
  log "NVIDIA driver installed. Reboot this machine, then run setup.sh again."
  exit 20
}

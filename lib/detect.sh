#!/usr/bin/env bash
# Collect CPU, RAM, disk, and GPU facts and write them as JSON.

detect_hardware() {
  local output="$1"
  local data_dir="$2"
  require_cmd python3
  python3 - "$output" "$data_dir" <<'PY'
import json
import os
import shutil
import subprocess
import sys

output, data_dir = sys.argv[1], sys.argv[2]


def run(cmd):
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return ""


def lscpu():
    info = {}
    for line in run(["lscpu"]).splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        info[key.strip()] = value.strip()
    return info


def cpu_block(info):
    flags = set(info.get("Flags", "").split())
    cores_per = int(info.get("Core(s) per socket") or "1")
    sockets = int(info.get("Socket(s)") or "1")
    threads = int(info.get("CPU(s)") or os.cpu_count() or 1)
    return {
        "model": info.get("Model name", "unknown"),
        "cores": cores_per * sockets,
        "threads": threads,
        "avx": "avx" in flags,
        "avx2": "avx2" in flags,
        "avx512": any(flag.startswith("avx512") for flag in flags),
    }


def ram_gb():
    total_kb = available_kb = 0
    with open("/proc/meminfo", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("MemTotal:"):
                total_kb = int(line.split()[1])
            elif line.startswith("MemAvailable:"):
                available_kb = int(line.split()[1])
    return total_kb / 1024 / 1024, available_kb / 1024 / 1024


def disk_free_gb(path):
    probe = path
    while not os.path.exists(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    stats = os.statvfs(probe)
    return stats.f_bavail * stats.f_frsize / 1024**3, probe


def secure_boot():
    if shutil.which("mokutil") is None:
        return "unknown"
    try:
        text = subprocess.check_output(
            ["mokutil", "--sb-state"], text=True, stderr=subprocess.STDOUT
        ).lower()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    if "enabled" in text:
        return "enabled"
    if "disabled" in text:
        return "disabled"
    return "unknown"


def vendor_of(line):
    lower = line.lower()
    if "10de" in lower or "nvidia" in lower:
        return "nvidia"
    if "1002" in lower or "amd" in lower or "advanced micro devices" in lower:
        return "amd"
    if "8086" in lower or "intel" in lower:
        return "intel"
    return "other"


def is_discrete(vendor, name):
    if vendor == "nvidia":
        return True
    if vendor == "intel":
        return False
    if vendor == "amd":
        upper = name.upper()
        if any(token in upper for token in ("RADEON RX", "RADEON PRO", "INSTINCT", "RADEON MI")):
            return True
        if "GRAPHICS" in upper and "RX" not in upper:
            return False
        return True
    return False


def lspci_gpus():
    text = run(["lspci", "-nn"])
    gpus = []
    for line in text.splitlines():
        lower = line.lower()
        if "vga compatible" not in lower and "3d controller" not in lower and "display controller" not in lower:
            continue
        name = line.split(": ", 1)[-1]
        vendor = vendor_of(line)
        gpus.append(
            {
                "name": name,
                "vendor": vendor,
                "discrete": is_discrete(vendor, name),
                "vram_gb": None,
                "driver": False,
            }
        )
    return gpus


def nvidia_smi_rows():
    if shutil.which("nvidia-smi") is None:
        return []
    text = run(
        [
            "nvidia-smi",
            "--query-gpu=name,memory.total",
            "--format=csv,noheader,nounits",
        ]
    )
    rows = []
    for line in text.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 2:
            continue
        try:
            vram_gb = int(round(float(parts[1]) / 1024))
        except ValueError:
            continue
        rows.append({"name": parts[0], "vram_gb": vram_gb})
    return rows


def merge_nvidia(gpus, rows):
    nvidia = [gpu for gpu in gpus if gpu["vendor"] == "nvidia"]
    if rows and not nvidia:
        for row in rows:
            gpus.append(
                {
                    "name": row["name"],
                    "vendor": "nvidia",
                    "discrete": True,
                    "vram_gb": row["vram_gb"],
                    "driver": True,
                }
            )
        return
    for gpu, row in zip(nvidia, rows):
        gpu["vram_gb"] = row["vram_gb"]
        gpu["driver"] = True
        gpu["name"] = row["name"]


def fit_block(gpus, ram_total):
    discrete = [gpu for gpu in gpus if gpu["discrete"]]
    nvidia = [gpu for gpu in discrete if gpu["vendor"] == "nvidia"]
    amd = [gpu for gpu in discrete if gpu["vendor"] == "amd"]
    allow_large = ram_total >= 8
    if nvidia:
        known = [gpu["vram_gb"] for gpu in nvidia if gpu["vram_gb"]]
        if known:
            budget = max(known)
            return {
                "runtime": "nvidia",
                "budget_gb": budget,
                "slow": False,
                "vram_known": True,
                "image_allowed": budget >= 8,
                "allow_large": allow_large,
            }
        return {
            "runtime": "nvidia",
            "budget_gb": None,
            "slow": False,
            "vram_known": False,
            "image_allowed": False,
            "allow_large": allow_large,
        }
    reserve = 4
    budget = round(max(0, ram_total - reserve), 2)
    runtime = "amd" if amd else "cpu"
    return {
        "runtime": runtime,
        "budget_gb": budget,
        "slow": True,
        "vram_known": False,
        "image_allowed": False,
        "allow_large": allow_large,
    }


info = lscpu()
ram_total, ram_available = ram_gb()
free_gb, probed = disk_free_gb(data_dir)
gpus = lspci_gpus()
merge_nvidia(gpus, nvidia_smi_rows())
payload = {
    "cpu": cpu_block(info),
    "ram_gb": round(ram_total, 2),
    "ram_available_gb": round(ram_available, 2),
    "disk_free_gb": round(free_gb, 2),
    "disk_probe_path": probed,
    "data_dir": data_dir,
    "secure_boot": secure_boot(),
    "gpus": gpus,
    "fit": fit_block(gpus, ram_total),
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

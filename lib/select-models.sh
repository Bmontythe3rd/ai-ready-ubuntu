#!/usr/bin/env bash
# Choose one model per task from catalog/models.json and the hardware report.

select_models() {
  local hardware_json="$1"
  local catalog_json="$2"
  local output_json="$3"
  require_cmd python3
  python3 - "$hardware_json" "$catalog_json" "$output_json" <<'PY'
import json
import sys

hardware_path, catalog_path, output_path = sys.argv[1:]
with open(hardware_path, encoding="utf-8") as handle:
    hardware = json.load(handle)
with open(catalog_path, encoding="utf-8") as handle:
    catalog = json.load(handle)

fit = hardware["fit"]
budget = fit.get("budget_gb")
margin = float(catalog.get("disk_margin", 1.2))
free_gb = float(hardware["disk_free_gb"])
tasks = catalog["tasks"]
task_order = ["chat", "code", "vision", "image"]

chosen = {}
skipped = []
notes = []


def smallest(task):
    models = tasks.get(task) or []
    return min(models, key=lambda model: model["min_gb"]) if models else None


def fitting(task):
    models = []
    for model in tasks.get(task) or []:
        if task == "image" and not fit.get("image_allowed"):
            continue
        if budget is None or model["min_gb"] <= budget:
            models.append(model)
    return models


def best(models):
    return max(models, key=lambda model: (model["min_gb"], -model["disk_gb"]))


def smaller_than(task, current):
    options = [
        model
        for model in fitting(task)
        if model["id"] != current["id"] and model["disk_gb"] < current["disk_gb"]
    ]
    if not options:
        return None
    return best(options)


def disk_total(selected):
    seen = set()
    total = 0.0
    for model in selected.values():
        if model["kind"] == "ollama":
            if model["id"] in seen:
                continue
            seen.add(model["id"])
        total += float(model["disk_gb"])
    return total


def disk_ok(selected, extra=0.0):
    return (disk_total(selected) + extra) * margin <= free_gb + 1e-6


if budget is None:
    skipped.append(
        {
            "task": "all",
            "reason": "NVIDIA GPU detected but the driver is not loaded, so VRAM is unknown. Reboot after the driver install and run setup.sh again.",
        }
    )
elif not fit.get("allow_large"):
    for task in task_order:
        skipped.append(
            {
                "task": task,
                "reason": "System RAM is under 8 GB, so large models are not downloaded.",
            }
        )
else:
    if not fit.get("image_allowed"):
        if fit.get("runtime") == "nvidia":
            image_reason = "Image generation needs an NVIDIA GPU with at least 8 GB VRAM."
        elif fit.get("runtime") == "amd":
            image_reason = "Image generation is set up for NVIDIA GPUs. This AMD machine still gets Ollama models sized to system RAM."
        else:
            image_reason = "Image generation needs an NVIDIA GPU. Chat, code, and vision models can still run on CPU."
        skipped.append({"task": "image", "reason": image_reason})

    for task in task_order:
        if task == "image" and not fit.get("image_allowed"):
            continue
        options = fitting(task)
        if not options:
            floor = smallest(task)
            need = floor["min_gb"] if floor else 0
            skipped.append(
                {
                    "task": task,
                    "reason": f"Needs at least {need:g} GB and this machine's budget is {budget:g} GB.",
                }
            )
            continue
        chosen[task] = best(options)

    disk_notes = []
    while chosen and not disk_ok(chosen):
        if "image" in chosen:
            dropped = chosen.pop("image")
            disk_notes.append(f"Dropped {dropped['id']} because disk space is short.")
            continue
        if "vision" in chosen:
            dropped = chosen.pop("vision")
            disk_notes.append(f"Dropped {dropped['id']} because disk space is short.")
            continue
        shrinkable = []
        for task, model in chosen.items():
            nxt = smaller_than(task, model)
            if nxt is not None:
                shrinkable.append((model["disk_gb"] - nxt["disk_gb"], task, nxt))
        if shrinkable:
            shrinkable.sort(reverse=True)
            _, task, nxt = shrinkable[0]
            previous = chosen[task]["id"]
            chosen[task] = nxt
            disk_notes.append(f"Stepped {task} down from {previous} to {nxt['id']} to fit the disk.")
            continue
        largest_task = max(chosen, key=lambda task: chosen[task]["disk_gb"])
        dropped = chosen.pop(largest_task)
        disk_notes.append(f"Dropped {dropped['id']} because disk space is short.")
    notes.extend(disk_notes)

embeddings = (tasks.get("embeddings") or [None])[0]
if budget is not None and embeddings and embeddings["min_gb"] <= budget:
    if disk_ok(chosen, extra=float(embeddings["disk_gb"])):
        chosen["embeddings"] = embeddings
    else:
        skipped.append(
            {
                "task": "embeddings",
                "reason": "Not enough free disk for the embedding model after the other downloads.",
            }
        )
elif budget is not None and embeddings:
    skipped.append(
        {
            "task": "embeddings",
            "reason": f"Needs at least {embeddings['min_gb']:g} GB and this machine's budget is {budget:g} GB.",
        }
    )

if fit.get("runtime") in {"cpu", "amd"} and chosen:
    notes.append(
        "AMD and CPU budgets use system RAM minus 4 GB. Models run slowly when they are not fully on a GPU."
    )
if fit.get("runtime") == "cpu" and not hardware["cpu"].get("avx"):
    notes.append("This CPU does not advertise AVX. Ollama CPU inference may not run.")

pull = []
for task in ("chat", "code", "vision", "embeddings"):
    model = chosen.get(task)
    if model and model["id"] not in pull:
        pull.append(model["id"])

payload = {
    "chosen": {task: model for task, model in chosen.items()},
    "skipped": skipped,
    "notes": notes,
    "pull": pull,
    "slow": bool(fit.get("slow")),
    "disk_gb": round(disk_total(chosen), 2),
    "disk_margin": margin,
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

format_report() {
  local hardware_json="$1"
  local selection_json="$2"
  local extras_json="${3:-}"
  local remove_extras=0
  require_cmd python3
  if [[ -z "$extras_json" ]]; then
    extras_json="$(mktemp)"
    printf '%s\n' '{}' >"$extras_json"
    remove_extras=1
  fi
  python3 - "$hardware_json" "$selection_json" "$extras_json" <<'PY'
import json
import sys

hardware_path, selection_path, extras_path = sys.argv[1:]
with open(hardware_path, encoding="utf-8") as handle:
    hardware = json.load(handle)
with open(selection_path, encoding="utf-8") as handle:
    selection = json.load(handle)
with open(extras_path, encoding="utf-8") as handle:
    extras = json.load(handle)

cpu = hardware["cpu"]
fit = hardware["fit"]
lines = ["AI-ready hardware and model plan", ""]
lines.append(f"CPU: {cpu['model']} ({cpu['cores']} cores / {cpu['threads']} threads)")
avx = ", ".join(
    name
    for name, present in (("AVX", cpu["avx"]), ("AVX2", cpu["avx2"]), ("AVX-512", cpu["avx512"]))
    if present
) or "no AVX"
lines.append(f"CPU flags: {avx}")
lines.append(
    f"RAM: {hardware['ram_gb']:.1f} GB total, {hardware['ram_available_gb']:.1f} GB available"
)
lines.append(
    f"Disk free: {hardware['disk_free_gb']:.1f} GB on {hardware['disk_probe_path']} (data dir {hardware['data_dir']})"
)
lines.append(f"Secure Boot: {hardware['secure_boot']}")
lines.append("")
lines.append("GPUs:")
if not hardware["gpus"]:
    lines.append("  none detected")
for gpu in hardware["gpus"]:
    kind = "discrete" if gpu["discrete"] else "integrated"
    vram = f"{gpu['vram_gb']} GB" if gpu.get("vram_gb") else "VRAM unknown"
    driver = "driver loaded" if gpu.get("driver") else "driver not loaded"
    lines.append(f"  {gpu['name']} [{gpu['vendor']}, {kind}, {vram}, {driver}]")
budget = fit.get("budget_gb")
budget_text = f"{budget:g} GB" if isinstance(budget, (int, float)) else "unknown"
lines.append(
    f"Fit: runtime {fit['runtime']}, budget {budget_text}, slow {str(fit['slow']).lower()}"
)
lines.append("")
lines.append("Models to download:")
if not selection["chosen"]:
    lines.append("  none")
for task, model in selection["chosen"].items():
    speed = " (slow off-GPU)" if selection.get("slow") and model["kind"] == "ollama" else ""
    lines.append(f"  {task}: {model['id']}{speed}")
lines.append(
    f"Download size about {selection['disk_gb']:.1f} GB plus {round((selection['disk_margin'] - 1) * 100)}% free-space margin."
)
if selection.get("notes"):
    lines.append("")
    lines.append("Notes:")
    for note in selection["notes"]:
        lines.append(f"  {note}")
if selection.get("skipped"):
    lines.append("")
    lines.append("Skipped:")
    for item in selection["skipped"]:
        lines.append(f"  {item['task']}: {item['reason']}")
errors = extras.get("download_errors") or []
if errors:
    lines.append("")
    lines.append("Download problems:")
    for error in errors:
        lines.append(f"  {error}")
if extras.get("url"):
    lines.append("")
    lines.append(f"Open WebUI: {extras['url']}")
lines.append("Local Open WebUI (this machine only): http://127.0.0.1:3000")
if extras.get("tailscale_pending"):
    lines.append("Tailscale is installed but not logged in. Run: tailscale up --ssh")
lines.append("The first Open WebUI account created becomes the administrator.")
if hardware["secure_boot"] == "enabled" and fit.get("runtime") == "nvidia" and not fit.get("vram_known"):
    lines.append("Secure Boot is enabled. The NVIDIA driver reboot may ask you to enroll a MOK.")
sys.stdout.write("\n".join(lines) + "\n")
PY
  if [[ "$remove_extras" -eq 1 ]]; then
    rm -f "$extras_json"
  fi
}

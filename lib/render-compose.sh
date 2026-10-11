#!/usr/bin/env bash
# Render the private Compose file and Open WebUI environment from hardware and model choices.

render_stack() {
  local hardware_json="$1"
  local selection_json="$2"
  require_cmd python3
  python3 - "$AI_ROOT" "$hardware_json" "$selection_json" "$AI_DATA_DIR" "$AI_ENV_FILE" "$AI_WEBUI_ENV_FILE" <<'PY'
import json
import pathlib
import sys

root, hardware_path, selection_path, data_dir, env_file, webui_env = sys.argv[1:]
root = pathlib.Path(root)
data_path = pathlib.Path(data_dir)
with open(hardware_path, encoding="utf-8") as handle:
    hardware = json.load(handle)
with open(selection_path, encoding="utf-8") as handle:
    selection = json.load(handle)
with open(root / "catalog" / "models.json", encoding="utf-8") as handle:
    catalog = json.load(handle)

secret = ""
env_path = pathlib.Path(env_file)
if env_path.exists():
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("WEBUI_SECRET_KEY="):
            secret = line.split("=", 1)[1].strip()
if not secret:
    raise SystemExit("WEBUI_SECRET_KEY is missing from /etc/ai-ready/env")

runtime = hardware["fit"]["runtime"]
image = "ollama/ollama:rocm" if runtime == "amd" else "ollama/ollama"
if runtime == "nvidia":
    extras = "    gpus: all\n"
elif runtime == "amd":
    extras = """    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    group_add:
      - video
    security_opt:
      - seccomp:unconfined
"""
else:
    extras = "\n"

image_model = selection["chosen"].get("image")
comfy = ""
webui_lines = [
    f"OLLAMA_BASE_URL=http://ollama:11434",
    f"WEBUI_SECRET_KEY={secret}",
    "ENABLE_PERSISTENT_CONFIG=false",
]
if image_model:
    workflow_name = image_model["workflow"]
    workflow_meta = catalog["workflows"][workflow_name]
    workflow = json.loads((root / workflow_meta["file"]).read_text(encoding="utf-8"))
    for node in workflow.values():
        kind = node.get("class_type")
        inputs = node.setdefault("inputs", {})
        if kind == "CheckpointLoaderSimple":
            ckpt = image_model["files"][0]["dest"].rsplit("/", 1)[-1]
            inputs["ckpt_name"] = ckpt
        elif kind == "UNETLoader":
            unet = next(item["dest"] for item in image_model["files"] if "diffusion_models/" in item["dest"])
            inputs["unet_name"] = unet.rsplit("/", 1)[-1]
        elif kind in {"EmptyLatentImage", "EmptySD3LatentImage"}:
            inputs["width"] = image_model["width"]
            inputs["height"] = image_model["height"]
        elif kind == "KSampler":
            inputs["steps"] = image_model["steps"]
            inputs["cfg"] = image_model["cfg"]
            inputs["sampler_name"] = image_model["sampler"]
            inputs["scheduler"] = image_model["scheduler"]
    rendered = data_path / "workflow-api.json"
    rendered.write_text(json.dumps(workflow, indent=2) + "\n", encoding="utf-8")
    model_name = image_model["files"][0]["dest"].rsplit("/", 1)[-1]
    if workflow_name == "flux":
        model_name = next(
            item["dest"].rsplit("/", 1)[-1]
            for item in image_model["files"]
            if item["dest"].startswith("diffusion_models/")
        )
    webui_lines.extend(
        [
            "ENABLE_IMAGE_GENERATION=true",
            "IMAGE_GENERATION_ENGINE=comfyui",
            f"IMAGE_GENERATION_MODEL={model_name}",
            f"IMAGE_SIZE={image_model['resolution']}",
            f"IMAGE_STEPS={image_model['steps']}",
            "COMFYUI_BASE_URL=http://comfyui:8188",
            "COMFYUI_WORKFLOW=" + json.dumps(workflow, separators=(",", ":")),
            "COMFYUI_WORKFLOW_NODES=" + json.dumps(workflow_meta["nodes"], separators=(",", ":")),
        ]
    )
    comfy = f"""  comfyui:
    image: ghcr.io/ai-dock/comfyui:latest-cuda
    restart: unless-stopped
    environment:
      COMFYUI_ARGS: "--listen 0.0.0.0 --port 8188"
      WEB_ENABLE_AUTH: "false"
      HF_TOKEN: "${{HF_TOKEN:-}}"
    volumes:
      - {data_dir}/comfyui/models:/workspace/ComfyUI/models
      - {data_dir}/comfyui/models:/workspace/models
      - {data_dir}/comfyui/output:/workspace/ComfyUI/output
    networks: [ai]
    gpus: all
"""
else:
    webui_lines.append("ENABLE_IMAGE_GENERATION=false")

template = (root / "compose" / "docker-compose.yml").read_text(encoding="utf-8")
rendered_compose = (
    template.replace("__OLLAMA_IMAGE__", image)
    .replace("__DATA_DIR__", data_dir)
    .replace("__OLLAMA_EXTRAS__", extras)
    .replace("__COMFY_SERVICE__", comfy)
)
(data_path / "docker-compose.yml").write_text(rendered_compose, encoding="utf-8")
webui_path = pathlib.Path(webui_env)
webui_path.write_text("\n".join(webui_lines) + "\n", encoding="utf-8")
webui_path.chmod(0o600)
PY
}

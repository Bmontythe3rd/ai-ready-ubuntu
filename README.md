# AI-ready Ubuntu

`setup.sh` turns a fresh Ubuntu Server 22.04 or 24.04 machine into a local AI host. It measures CPU, RAM, disk, and GPU, installs Docker, Ollama, Open WebUI, and Tailscale, and downloads only the models that hardware can run.

Open WebUI is the browser UI (the project sometimes called OpenWebAI). Ollama serves chat, code, vision, and embedding models. ComfyUI serves image generation on NVIDIA GPUs with at least 8 GB of VRAM.

## Run it

On the Ubuntu server:

```bash
git clone https://github.com/Bmontythe3rd/ai-ready-ubuntu.git
cd ai-ready-ubuntu
sudo ./setup.sh
```

`--yes` downloads the selected models without asking. `--detect-only` prints the hardware fit and model plan and does not install anything. That mode also runs on non-Ubuntu machines.

Useful environment variables:

- `TAILSCALE_AUTHKEY` logs the machine into Tailscale without a prompt. Create a reusable, non-ephemeral key in the Tailscale admin console.
- `HF_TOKEN` is a Hugging Face token. Some image checkpoints require it.
- `AI_DATA_DIR` is where models and Compose files go. The default is `/var/lib/ai-ready`.

The first Open WebUI account created in the browser becomes the administrator.

## What gets installed

Docker Compose keeps Ollama and ComfyUI off the host network. Open WebUI is published only on `127.0.0.1:3000`. Tailscale Serve publishes that local port on your tailnet. The firewall allows OpenSSH and Tailscale, and does not open ports 3000, 8188, or 11434.

A NVIDIA GPU without a working driver gets `ubuntu-drivers`, then the script exits with status 20. Reboot, enroll the MOK if Secure Boot asks, and run `sudo ./setup.sh` again. Finished stages are recorded in `/var/lib/ai-ready/state`.

AMD and CPU-only machines still get Ollama and Open WebUI. Model size is based on system RAM minus 4 GB, and the report marks those models as slow. Image generation is skipped. Below 8 GB of system RAM, large models are not downloaded.

## Models

`catalog/models.json` is the list the selector uses. Edit the tags or sizes, then run `sudo ./setup.sh` again. Ollama pulls are skipped when the model is already present.

The memory numbers already leave about 2 GB for context. NVIDIA cards use VRAM, rounded to the nearest GB. One heavy model is expected to be loaded at a time. If the disk cannot hold the full set plus a 20% margin, the script drops image generation, then vision, then steps the chat and code models down.

Open WebUI reads image settings from `/etc/ai-ready/openwebui.env` on every start (`ENABLE_PERSISTENT_CONFIG=false`). The ComfyUI workflow shipped for Stable Diffusion checkpoints is `comfy/workflow-api.json`. FLUX uses `comfy/workflow-flux-api.json`.

## Check the server

After a NVIDIA reboot, `nvidia-smi` should succeed. Then:

```bash
docker compose -p ai-ready --env-file /etc/ai-ready/env -f /var/lib/ai-ready/docker-compose.yml ps
docker compose -p ai-ready --env-file /etc/ai-ready/env -f /var/lib/ai-ready/docker-compose.yml exec ollama ollama list
ss -ltnp | grep -E ':3000|:8188|:11434'
```

Open WebUI should listen on `127.0.0.1:3000` only. Nothing should listen on 8188 or 11434 on a public interface. The report at `/var/lib/ai-ready/report.txt` has the Tailscale URL.

# Running Hermes Agent on a Local LLM (Ollama) — The Undocumented Pitfalls

*by [StochasticGravy](https://github.com/StochasticGravy)*

> **TL;DR:** Getting Hermes Agent v0.13.0 (Nous Research) off cloud providers and onto a local Ollama model involves several non-obvious bugs and undocumented config quirks. This writeup covers every failure, what caused it, and how to fix it — ending with a one-command workflow and companion scripts that make switching models trivial.

**Setup:** Windows 11, NVIDIA RTX GPU (16GB VRAM), Hermes v0.13.0, Ollama

**Companion scripts** (in this repo):
- `hermes-use-model.bat` + `hermes-use-model.ps1` — pull any model and configure Hermes in one command
- `restart-hermes.bat` — kill and relaunch Hermes cleanly

---

## Part 1: How This All Fits Together

Before diving into the bugs, here's the architecture — it makes everything else make sense.

**Ollama** is a local model runner. It downloads AI models from [ollama.com/library](https://ollama.com/library), loads them into your GPU's VRAM, and serves them through a local web API at `http://localhost:11434`. That API is intentionally compatible with OpenAI's format, so any tool that supports OpenAI can also point at Ollama — including Hermes.

**Hermes** connects to Ollama exactly like it connects to OpenAI: it sends your conversation to the API and gets a response back. The difference is the computation runs on your GPU instead of a remote server. When it's working you'll see GPU memory spike in Task Manager during generation.

**The model file** (e.g., `gemma4:e4b`) is typically a 2–8GB file Ollama downloads once and stores locally. After that, no internet is needed to run it. The tag after the colon (`e4b`) describes the quantization — `e4b` means 4-bit quantized, compressed to use less VRAM while keeping most of the quality.

**Context window** is how much text the model can hold in mind at once — conversation history, tool definitions, system prompt, everything. Ollama defaults to 2048 tokens. Hermes needs 32K–64K minimum just for its own overhead. This mismatch causes silent failures and is one of the two biggest gotchas.

---

## Part 2: Managing Ollama on Windows

You need Ollama running before Hermes can use it. On Windows this trips people up because the tray icon is inconsistent.

### Method A: System Tray

After installing Ollama, it may appear in the Windows system tray (bottom-right near the clock). If you don't see it, click the **^** arrow to reveal hidden tray icons — it's often tucked there. Right-clicking gives Start/Stop/Quit options.

### Method B: PowerShell (always works, no tray needed)

**Check if Ollama is running:**
```powershell
Get-Process -Name "ollama" -ErrorAction SilentlyContinue
```

**Start Ollama in the background (no window):**
```powershell
Start-Process -FilePath (Get-Command ollama).Source -ArgumentList "serve" -WindowStyle Hidden
```

**Stop Ollama gracefully:**
```powershell
Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force
```

**Restart Ollama (stop + start in one block):**
```powershell
Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process -FilePath (Get-Command ollama).Source -ArgumentList "serve" -WindowStyle Hidden
```

**Verify Ollama is up and list installed models:**
```powershell
Invoke-RestMethod -Uri "http://localhost:11434/api/tags" | Select-Object -ExpandProperty models | ForEach-Object { $_.name }
```

**Run in the foreground (for debugging):**
```powershell
ollama serve
```
Hit `Ctrl+C` to stop. Shows logs directly — useful when diagnosing loading issues.

---

## Part 3: The Bugs

### Bug 1: `provider: ollama` is not a valid provider name

The first instinct when pointing Hermes at Ollama is:

```yaml
model:
  provider: ollama       # ← WRONG
  default: gemma4:e4b
  base_url: http://localhost:11434/v1
```

**Error:**
```
auxiliary_client: resolve_provider_client: unknown provider 'ollama'
```

Hermes has no `ollama` provider. It has a `custom` provider for any OpenAI-compatible self-hosted endpoint — which is exactly what Ollama exposes at `/v1`.

**Fix:**
```yaml
model:
  provider: custom          # ← correct
  default: gemma4:e4b
  base_url: http://localhost:11434/v1
  api_key: ollama
  api_mode: chat_completions
```

---

### Bug 2: Active cloud API keys silently override your local config (#4172 / #12146)

Even with `provider: custom` correctly set in `config.yaml`, Hermes routes back to cloud if any cloud API key is present and uncommented in `.env`.

Affected: `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and likely others.

The auto-detection logic treats an active key as intent, and it wins over your explicit config. The session looks fine — the status bar shows your local model name — but inference is going to cloud. Your GPU stays at 0% and responses come back instantly with no generation latency.

**Fix — two parts:**

1. Comment out any cloud API keys you aren't actively using:
```
#OPENROUTER_API_KEY=sk-or-v1-...
#ANTHROPIC_API_KEY=sk-ant-...
```

2. Explicitly pin the provider in `.env`:
```
HERMES_INFERENCE_PROVIDER=custom
HERMES_API_BASE_URL=http://localhost:11434/v1
HERMES_API_KEY=ollama
HERMES_MODEL=gemma4:e4b
```

`HERMES_INFERENCE_PROVIDER=custom` is what actually locks it. Without it, any detected cloud key wins regardless of config.

> **Note:** If you need `OPENAI_API_KEY` for image generation (dall-e-3), keep it set — `HERMES_INFERENCE_PROVIDER=custom` prevents it from hijacking chat while still allowing image gen to use it.

---

### Bug 3: Ollama's 2K default context window silently breaks Hermes

Ollama defaults to 2048 tokens for all models. Hermes needs 32K–64K minimum. With 2K you get empty responses in oneshot mode (exit code 0, no output), sessions that break down mid-task, or truncated tool outputs — all silently, no error.

**This CLI flag does not exist:**
```
ollama run gemma4:e4b --num_ctx 65536   # ❌ invalid
```

**Old fix — Modelfile (one per model, tedious):**
```
FROM gemma4:e4b
PARAMETER num_ctx 65536
```
```bash
ollama create gemma4-hermes -f gemma4.Modelfile
```

**Better fix — one global environment variable, set once:**
```powershell
[System.Environment]::SetEnvironmentVariable("OLLAMA_NUM_CTX", "65536", "User")
```

Restart Ollama after setting it. Every model you pull from that point forward gets 64K context automatically — no Modelfile ever needed.

---

### Bug 4: Free OpenRouter models are deprecated and return 404

If you're testing with a cloud model before going local, the commonly cited free models are gone:

- `qwen/qwen3-8b:free` → **HTTP 404**
- `qwen/qwen3.6-plus:free` → **HTTP 404**

**Working free model:** `openrouter/owl-alpha` — Nous Research's own hosted agentic model, tuned specifically for Hermes tool use. Confirmed working as of May 2026.

---

### Bug 5: Image generation hangs silently forever

Default config often has:
```yaml
image_gen:
  provider: openai-codex
  model: dall-e-3
```

Without `OPENAI_API_KEY`, Hermes enters an infinite retry loop — no timeout, no error, just hangs.

**Fix:** Add `OPENAI_API_KEY` to `.env`. Combined with `HERMES_INFERENCE_PROVIDER=custom` it will only be used for image gen, not chat.

**Alternative — FAL.ai (has a free tier):**
```yaml
image_gen:
  provider: fal
  model: fal-ai/flux/schnell
```
Requires `FAL_KEY` in `.env`.

---

## Part 4: The One-Command Workflow

### One-time setup

Set the global context window — do this once, never again:

```powershell
[System.Environment]::SetEnvironmentVariable("OLLAMA_NUM_CTX", "65536", "User")
```

Then restart Ollama (Method B above).

### Switching to any model

Use the `hermes-use-model` script included in this repo:

```bat
hermes-use-model.bat gemma4:e4b
```

From PowerShell, include the path or navigate to the folder first:

```powershell
cd "C:\path\to\scripts"
.\hermes-use-model.bat gemma4:e4b
```

Or with full path:

```powershell
& "C:\path\to\scripts\hermes-use-model.bat" gemma4:e4b
```

Other examples — any model from [ollama.com/library](https://ollama.com/library) works:

```bat
hermes-use-model.bat llama3.2:3b
hermes-use-model.bat mistral:7b
hermes-use-model.bat deepseek-r1:8b
hermes-use-model.bat qwen3.5:9b
```

**What the script does:**
1. Sets `OLLAMA_NUM_CTX=65536` as a user env var if not already set, then restarts Ollama to apply it
2. Starts Ollama in the background if it isn't running
3. Pulls the model from Ollama's servers if not already installed (skips if present)
4. Updates `model.default` in `config.yaml`
5. Updates `HERMES_MODEL` in `.env`

**Confirmed output (clean run):**
```
=== Hermes Model Switcher ===
Target model: gemma4:e4b

[1/5] OLLAMA_NUM_CTX=65536 already set. OK.
[2/5] Checking Ollama...
      Ollama is running. OK.
[3/5] Checking installed models...
      9 model(s) installed locally.
[4/5] Model: gemma4:e4b
      Already installed (gemma4:e4b). Skipping pull.
[5/5] Updating Hermes config...
      config.yaml  ->  model.default = gemma4:e4b
      .env           ->  HERMES_MODEL = gemma4:e4b
---------------------------------------------------------
  Done!
  Model   : gemma4:e4b
  Provider: Ollama (localhost:11434)
  Context : 65536 tokens

  Restart Hermes to apply: press Ctrl+C in the Hermes
  window, then run 'hermes' again.
---------------------------------------------------------
```

### Session-only override (no config change)

If you just want to try a model without committing to it, Hermes supports a `--model` flag that applies for that session only:

```
hermes --model gemma4:e4b
```

Config files stay untouched. Close and reopen Hermes and it goes back to whatever config.yaml says.

### Restarting Hermes

Use the included `restart-hermes.bat` — it kills any running Hermes process and opens a fresh session in a new window:

```bat
restart-hermes.bat
```

Or manually: `Ctrl+C` in the Hermes window, then `hermes`.

### Verifying local inference is actually running

Open Task Manager (`Ctrl+Shift+Esc`) → Performance → GPU. During generation:
- GPU memory usage should spike (model weights loaded into VRAM)
- GPU compute utilization should be active

If both stay at 0% during generation, you're still routing to cloud. Re-check Bug #2.

---

## Part 5: Listing Available Models

There are four distinct model lists in this stack — they're easy to confuse.

### 1. Locally installed models (ready to use right now)
```powershell
ollama list
```
Shows every model downloaded to your machine. These run fully offline on your GPU.

### 2. Currently loaded in GPU memory
```powershell
ollama ps
```
Only shows what's actively occupying VRAM. Empty between sessions when Ollama has unloaded the model.

### 3. Interactive picker inside Hermes
While Hermes is running, type the slash command:
```
/model
```
Opens a full interactive picker showing your local Ollama models and any authenticated cloud providers side by side. This is the easiest way to browse and switch mid-session without touching any files.

### 4. What's available to pull from Ollama's library
```powershell
ollama search gemma     # search by keyword
ollama search qwen
ollama search deepseek
```
Or browse visually at [ollama.com/library](https://ollama.com/library) — shows sizes, quantization tags, and VRAM requirements for each model.

**A note on cloud vs local:** Hermes maintains its own catalog of cloud-hosted models (accessible via Ollama's paid cloud API — things like `gemma4:31b`, `deepseek-v3.1:671b`, `kimi-k2:1t`). These appear alongside your local models in the `/model` picker. They're not the same as locally installed models — they run on remote servers and require an Ollama account key. If you're running local, ignore them.

---

## Part 6: Full Working Config

**`%APPDATA%\..\Local\hermes\config.yaml` (model section):**
```yaml
model:
  provider: custom
  default: gemma4:e4b
  base_url: http://localhost:11434/v1
  api_key: ollama
  api_mode: chat_completions

image_gen:
  provider: openai-codex
  use_gateway: false
  model: dall-e-3
```

**`%APPDATA%\..\Local\hermes\.env` (relevant lines):**
```
#OPENROUTER_API_KEY=...      # COMMENTED — prevents Bug #2
HERMES_INFERENCE_PROVIDER=custom
HERMES_API_BASE_URL=http://localhost:11434/v1
HERMES_API_KEY=ollama
HERMES_MODEL=gemma4:e4b
OPENAI_API_KEY=sk-proj-...   # image gen only; chat still goes to Ollama
OLLAMA_MAX_LOADED_MODELS=1
```

---

## Part 7: Bug Summary

| # | Bug | Symptom | Fix |
|---|-----|---------|-----|
| 1 | `provider: ollama` invalid | `unknown provider 'ollama'` error | Use `provider: custom` |
| 2 | Cloud key overrides local config (#4172) | 0% GPU, instant responses | Comment cloud keys; set `HERMES_INFERENCE_PROVIDER=custom` |
| 3 | Ollama 2K default context | Empty/broken responses silently | Set `OLLAMA_NUM_CTX=65536` as user env var |
| 4 | `--num_ctx` CLI flag | Flag doesn't exist | Use env var or Modelfile only |
| 5 | Free OpenRouter models 404 | HTTP 404 | Use `openrouter/owl-alpha` |
| 6 | Image gen infinite hang | Hangs silently forever | Add `OPENAI_API_KEY` or switch to `provider: fal` |

---

## Part 8: Notes on Running Multiple Agents

Running Hermes on cloud (`owl-alpha` via OpenRouter) while simultaneously running a local agent via Ollama is feasible. Cloud inference runs on Nous Research's servers, contributing nothing to local GPU load. You can run a fully-loaded Ollama session alongside a cloud Hermes session with no meaningful resource conflict.

---

## Scripts in This Repo

| Script | What it does |
|--------|-------------|
| `hermes-use-model.bat` | One-command model switcher (calls the PS1) |
| `hermes-use-model.ps1` | The actual logic — pull, configure, restart Ollama as needed |
| `restart-hermes.bat` | Kill any running Hermes process and open a fresh session |

---

## Credit

Debugging assistance by **Claude Sonnet 4.5** (Anthropic), running autonomously in Cowork mode. Claude performed live diagnosis across two full context windows (~200K tokens each) — reading error logs, cross-referencing Hermes source code and GitHub issues, writing and iterating the fix scripts in real time. Bugs #1 and #2 in particular required correlating silent runtime behavior against known tracked issues. The `OLLAMA_NUM_CTX` global solution (eliminating per-model Modelfiles entirely) was also surfaced during that session.

---

## Environment

- OS: Windows 11
- GPU: NVIDIA RTX (16GB VRAM)
- Hermes: v0.13.0 (Nous Research)
- Ollama: current release
- Models tested: `gemma4:e4b`, `gemma4:e2b`, `qwen3.5:9b`, `llama3.2`
- Date: May 2026

---

*Browse local models at [ollama.com/library](https://ollama.com/library). File Hermes issues at [github.com/nousresearch/hermes-agent](https://github.com/nousresearch/hermes-agent).*

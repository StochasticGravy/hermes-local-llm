# hermes-use-model.ps1
# Pull any Ollama model and point Hermes at it automatically.
# No Modelfile needed. No tray icon needed.
#
# Usage:   .\hermes-use-model.ps1 <model-name>
# Example: .\hermes-use-model.ps1 gemma4:e4b
# Example: .\hermes-use-model.ps1 llama3.2:3b
# Example: .\hermes-use-model.ps1 qwen3.5:9b
# Example: .\hermes-use-model.ps1 mistral:7b
# Example: .\hermes-use-model.ps1 deepseek-r1:8b
#
# Browse all models at: https://ollama.com/library

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ModelName
)

$ConfigPath   = "$env:LOCALAPPDATA\hermes\config.yaml"
$EnvPath      = "$env:LOCALAPPDATA\hermes\.env"
$OllamaNumCtx = "65536"
$OllamaUrl    = "http://localhost:11434"

Write-Host ""
Write-Host "=== Hermes Model Switcher ===" -ForegroundColor Cyan
Write-Host "Target model: $ModelName" -ForegroundColor White
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# HELPER: Stop Ollama gracefully
# ─────────────────────────────────────────────────────────────────────────────
function Stop-Ollama {
    $procs = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "      Stopping Ollama..." -ForegroundColor DarkYellow
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host "      Ollama stopped." -ForegroundColor Green
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPER: Start Ollama in the background (no tray required)
# ─────────────────────────────────────────────────────────────────────────────
function Start-Ollama {
    Write-Host "      Starting Ollama in background..." -ForegroundColor DarkYellow
    $ollamaExe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollamaExe) {
        Write-Host "      ERROR: 'ollama' not found in PATH. Is Ollama installed?" -ForegroundColor Red
        Write-Host "      Download from: https://ollama.com/download" -ForegroundColor DarkYellow
        exit 1
    }
    Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
    # Wait for it to become ready
    $retries = 10
    for ($i = 0; $i -lt $retries; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -Method GET -TimeoutSec 2 | Out-Null
            Write-Host "      Ollama is ready." -ForegroundColor Green
            return $true
        } catch { }
    }
    Write-Host "      WARNING: Ollama may not have started correctly. Continuing anyway..." -ForegroundColor DarkYellow
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Set OLLAMA_NUM_CTX permanently as a user environment variable.
#         This gives every pulled model 64K context — no Modelfile ever needed.
# ─────────────────────────────────────────────────────────────────────────────
$currentCtx = [System.Environment]::GetEnvironmentVariable("OLLAMA_NUM_CTX", "User")
$needsRestart = $false

if ($currentCtx -ne $OllamaNumCtx) {
    Write-Host "[1/5] Setting OLLAMA_NUM_CTX=$OllamaNumCtx (user environment)..." -ForegroundColor Yellow
    [System.Environment]::SetEnvironmentVariable("OLLAMA_NUM_CTX", $OllamaNumCtx, "User")
    $env:OLLAMA_NUM_CTX = $OllamaNumCtx
    $needsRestart = $true
    Write-Host "      Set. Ollama will be restarted to apply it." -ForegroundColor DarkYellow
} else {
    Write-Host "[1/5] OLLAMA_NUM_CTX=$OllamaNumCtx already set. OK." -ForegroundColor Green
}
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Ensure Ollama is running. Restart if needed to apply new env var.
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[2/5] Checking Ollama..." -ForegroundColor Yellow

$ollamaRunning = $false
try {
    Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -Method GET -TimeoutSec 5 | Out-Null
    $ollamaRunning = $true
} catch { }

if ($needsRestart -and $ollamaRunning) {
    Write-Host "      Restarting Ollama to apply OLLAMA_NUM_CTX..." -ForegroundColor DarkYellow
    Stop-Ollama
    Start-Ollama | Out-Null
} elseif (-not $ollamaRunning) {
    Write-Host "      Ollama not running. Starting it..." -ForegroundColor DarkYellow
    Start-Ollama | Out-Null
} else {
    Write-Host "      Ollama is running. OK." -ForegroundColor Green
}
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Get list of locally available models
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[3/5] Checking installed models..." -ForegroundColor Yellow

# Primary check: use 'ollama list' CLI — most reliable, matches what you actually see
$ollamaListLines = & ollama list 2>$null | Select-Object -Skip 1  # skip header row
$localModelNames = $ollamaListLines | ForEach-Object { ($_ -split '\s+')[0].Trim() } | Where-Object { $_ -ne '' }

# Fallback: also query REST API
try {
    $tagsResponse = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -Method GET -TimeoutSec 10
    $apiModels = $tagsResponse.models | ForEach-Object { $_.name }
    # Merge both lists, deduplicate
    $localModels = ($localModelNames + $apiModels) | Sort-Object -Unique
} catch {
    $localModels = $localModelNames
}

Write-Host "      $($localModels.Count) model(s) installed locally." -ForegroundColor Green
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Pull the model if not already present
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[4/5] Model: $ModelName" -ForegroundColor Yellow

# Check if already present — exact match, :latest variant, or prefix match (no tag specified)
$ModelNameClean = $ModelName.Trim()
$alreadyHave = $localModels | Where-Object {
    $_.Trim() -eq $ModelNameClean -or
    $_.Trim() -eq "${ModelNameClean}:latest" -or
    ($ModelNameClean -notmatch ':' -and $_.Trim() -like "${ModelNameClean}:*")
}

if ($alreadyHave) {
    Write-Host "      Already installed ($($alreadyHave -join ', ')). Skipping pull." -ForegroundColor Green
} else {
    Write-Host "      Not found locally. Pulling from https://ollama.com/library..." -ForegroundColor White
    Write-Host "      (Large models may take several minutes to download)" -ForegroundColor DarkGray
    Write-Host ""
    & ollama pull $ModelName
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "      ERROR: ollama pull failed (exit code $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "      Check the model name at: https://ollama.com/library" -ForegroundColor DarkYellow
        Write-Host "      Example valid names: gemma4:e4b  llama3.2:3b  qwen3.5:9b  mistral:7b" -ForegroundColor DarkGray
        exit 1
    }
    Write-Host ""
    Write-Host "      Pull complete." -ForegroundColor Green
}
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Update Hermes config.yaml and .env
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[5/5] Updating Hermes config..." -ForegroundColor Yellow

# --- config.yaml: update model.default (only within the model: block) ---
if (Test-Path $ConfigPath) {
    $lines = Get-Content $ConfigPath
    $inModelBlock = $false
    $replaced = $false
    $newLines = $lines | ForEach-Object {
        if ($_ -match '^model:') {
            $inModelBlock = $true
        } elseif ($inModelBlock -and $_ -notmatch '^[ \t]') {
            $inModelBlock = $false
        }
        if ($inModelBlock -and -not $replaced -and $_ -match '^  default: ') {
            $replaced = $true
            "  default: $ModelName"
        } else {
            $_
        }
    }
    if ($replaced) {
        $newLines | Set-Content $ConfigPath -Encoding UTF8
        Write-Host "      config.yaml  ->  model.default = $ModelName" -ForegroundColor Green
    } else {
        Write-Host "      WARNING: Could not locate model.default in config.yaml." -ForegroundColor DarkYellow
        Write-Host "      Edit manually: $ConfigPath" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "      WARNING: config.yaml not found at $ConfigPath" -ForegroundColor Red
}

# --- .env: update or insert HERMES_MODEL ---
if (Test-Path $EnvPath) {
    $envLines = Get-Content $EnvPath
    $modelLineExists = $envLines | Where-Object { $_ -match '^HERMES_MODEL=' }
    if ($modelLineExists) {
        $envLines = $envLines | ForEach-Object {
            if ($_ -match '^HERMES_MODEL=') { "HERMES_MODEL=$ModelName" } else { $_ }
        }
    } else {
        $envLines += "HERMES_MODEL=$ModelName"
    }
    $envLines | Set-Content $EnvPath -Encoding UTF8
    Write-Host "      .env           ->  HERMES_MODEL = $ModelName" -ForegroundColor Green
} else {
    Write-Host "      WARNING: .env not found at $EnvPath" -ForegroundColor Red
}

Write-Host ""
Write-Host "---------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Done!" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Model   : $ModelName" -ForegroundColor White
$ollamaAddr = "localhost" + ":11434"
Write-Host "  Provider: Ollama ($ollamaAddr)" -ForegroundColor White
Write-Host "  Context : $OllamaNumCtx tokens" -ForegroundColor White
Write-Host ""
Write-Host "  To apply permanently (updates config.yaml + .env):" -ForegroundColor Yellow
Write-Host "    Restart Hermes: Ctrl+C, then run 'hermes'" -ForegroundColor Yellow
Write-Host ""
Write-Host "  To try this session only (no config change):" -ForegroundColor Cyan
Write-Host "    hermes --model $ModelName" -ForegroundColor White
Write-Host "---------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

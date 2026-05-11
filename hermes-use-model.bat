@echo off
:: hermes-use-model.bat
:: Pull any Ollama model and point Hermes at it — one command.
:: No Modelfile. No tray icon. No manual config editing.
::
:: Usage:   hermes-use-model.bat <model-name>
:: Example: hermes-use-model.bat gemma4:e4b
:: Example: hermes-use-model.bat llama3.2:3b
:: Example: hermes-use-model.bat qwen3.5:9b
:: Example: hermes-use-model.bat mistral:7b
::
:: Browse all models: https://ollama.com/library

if "%~1"=="" (
    echo.
    echo  Usage: hermes-use-model.bat ^<model-name^>
    echo.
    echo  Examples:
    echo    hermes-use-model.bat gemma4:e4b
    echo    hermes-use-model.bat llama3.2:3b
    echo    hermes-use-model.bat qwen3.5:9b
    echo    hermes-use-model.bat mistral:7b
    echo    hermes-use-model.bat deepseek-r1:8b
    echo.
    echo  Browse all models at: https://ollama.com/library
    echo.
    exit /b 1
)

powershell -ExecutionPolicy Bypass -File "%~dp0hermes-use-model.ps1" "%~1"

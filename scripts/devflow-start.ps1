<#
.SYNOPSIS
    FlowPilot AI 一键启动脚本（Windows 本地 SQLite 演示模式，无需 Docker）。
.DESCRIPTION
    自动定位 Python 虚拟环境与 Node 运行时，后台启动 FastAPI 后端和 Next.js 前端，
    等待健康检查通过后自动打开浏览器，并把进程 PID 写入 .data\devflow-pids.json。
.PARAMETER BackendPort
    后端端口，默认 8010（避开 Docker milvus-attu 占用的 8000）。
.PARAMETER FrontendPort
    前端端口，默认 3000。
.PARAMETER UseConfiguredLLM
    使用 .env 中已配置的 LLM_API_KEY 启用模型生成；默认使用无模型兜底回答。
.PARAMETER NoBrowser
    启动后不自动打开浏览器。
#>
param(
    [switch]$UseConfiguredLLM,
    [switch]$NoBrowser,
    [ValidateRange(1, 65535)]
    [int]$BackendPort = 8010,
    [ValidateRange(1, 65535)]
    [int]$FrontendPort = 3000
)

$ErrorActionPreference = "Stop"

# ---------- 路径 ----------
$projectRoot = Split-Path -Parent $PSScriptRoot
$backendDirectory = Join-Path $projectRoot "backend"
$frontendDirectory = Join-Path $projectRoot "frontend"
$pythonPath = Join-Path $backendDirectory ".venv\Scripts\python.exe"
$dataDirectory = Join-Path $projectRoot ".data"
$pidFilePath = Join-Path $dataDirectory "devflow-pids.json"
$backendOutputLog = Join-Path $dataDirectory "devflow-backend.out.log"
$backendErrorLog = Join-Path $dataDirectory "devflow-backend.err.log"
$frontendOutputLog = Join-Path $dataDirectory "devflow-frontend.out.log"
$frontendErrorLog = Join-Path $dataDirectory "devflow-frontend.err.log"

function Write-Step([string]$message) {
    Write-Host "[FlowPilot] $message" -ForegroundColor Cyan
}

function Test-PortListening([int]$port) {
    $connection = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    return $null -ne $connection
}

function Test-ServiceHealth([string]$url) {
    try {
        Invoke-RestMethod -Uri $url -TimeoutSec 2 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# ---------- 前置检查 ----------
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    throw "未找到后端虚拟环境 backend\.venv，请先完成部署（创建虚拟环境并安装 backend\requirements.txt）。"
}
if (-not (Test-Path -LiteralPath (Join-Path $frontendDirectory "node_modules") -PathType Container)) {
    throw "未找到 frontend\node_modules，请先在 frontend 目录执行 npm install。"
}

# ---------- 重复启动检测 ----------
$alreadyRunning = $false
if (Test-Path -LiteralPath $pidFilePath -PathType Leaf) {
    try {
        $savedPids = Get-Content -LiteralPath $pidFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $backendAlive = $false
        $frontendAlive = $false
        if ($savedPids.backend_pid) {
            $backendAlive = $null -ne (Get-Process -Id $savedPids.backend_pid -ErrorAction SilentlyContinue)
        }
        if ($savedPids.frontend_pid) {
            $frontendAlive = $null -ne (Get-Process -Id $savedPids.frontend_pid -ErrorAction SilentlyContinue)
        }
        if ($backendAlive -and $frontendAlive) {
            $alreadyRunning = $true
        }
    }
    catch {
        $alreadyRunning = $false
    }
}

if ($alreadyRunning -and (Test-ServiceHealth "http://127.0.0.1:$BackendPort/health")) {
    Write-Step "检测到服务已在运行，直接打开浏览器，不重复启动。"
    if (-not $NoBrowser) {
        Start-Process "http://127.0.0.1:$FrontendPort"
    }
    Write-Host "前端：http://127.0.0.1:$FrontendPort" -ForegroundColor Green
    Write-Host "后端：http://127.0.0.1:$BackendPort" -ForegroundColor Green
    return
}

if (Test-PortListening $BackendPort) {
    throw "端口 $BackendPort 已被其他程序占用，请关闭占用程序或使用 -BackendPort 指定其他端口。"
}
if (Test-PortListening $FrontendPort) {
    throw "端口 $FrontendPort 已被其他程序占用，请关闭占用程序或使用 -FrontendPort 指定其他端口。"
}

# ---------- 定位 Node 运行时 ----------
# 只接受真正的 node.exe，排除 C:\Windows\System32 下无扩展名的空 node 文件等干扰。
$nodeCandidates = New-Object System.Collections.Generic.List[string]

# 1) 常见安装位置优先（本机 D:\nodejs 为正式安装，路径无空格）
$commonNodePaths = @(
    "D:\nodejs\node.exe",
    "C:\Program Files\nodejs\node.exe",
    "C:\Program Files (x86)\nodejs\node.exe"
)
foreach ($candidate in $commonNodePaths) {
    $nodeCandidates.Add($candidate)
}

# 2) PATH 中解析到的 node（仅保留 node.exe）
foreach ($resolved in (Get-Command node -All -ErrorAction SilentlyContinue)) {
    if ($resolved.Source -and [IO.Path]::GetFileName($resolved.Source).ToLower() -eq "node.exe") {
        $nodeCandidates.Add($resolved.Source)
    }
}

# 3) DoubaoWork 运行时（兜底，路径含空格，需靠参数引号处理）
$runtimeGlob = Join-Path $env:LOCALAPPDATA "DoubaoWork\User Data\sandbox_runtime\bases\*\node\node.exe"
foreach ($candidate in (Get-ChildItem -Path $runtimeGlob -ErrorAction SilentlyContinue)) {
    $nodeCandidates.Add($candidate.FullName)
}

$nodeCandidates = $nodeCandidates | Select-Object -Unique

# 逐个验证：文件存在、同目录自带 npm-cli.js、能实际执行 --version
$nodeExe = $null
foreach ($candidate in $nodeCandidates) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $candidateNpmCli = Join-Path (Split-Path -Parent $candidate) "node_modules\npm\bin\npm-cli.js"
    if (-not (Test-Path -LiteralPath $candidateNpmCli -PathType Leaf)) { continue }
    try {
        $versionOutput = & $candidate --version 2>$null
        if ($LASTEXITCODE -eq 0 -and "$versionOutput" -match "^v\d+") {
            $nodeExe = $candidate
            break
        }
    }
    catch { continue }
}

if (-not $nodeExe) {
    throw "未找到可用的 Node.js（需要 node.exe 且自带 npm）。请确认 Node.js 已正确安装；C:\Windows\System32 下无扩展名的空 node 文件会被自动忽略。"
}
$nodeDirectory = Split-Path -Parent $nodeExe
$env:PATH = "$nodeDirectory;$env:PATH"
$npmCliPath = Join-Path $nodeDirectory "node_modules\npm\bin\npm-cli.js"
Write-Step "使用 Node：$nodeExe（$(& $nodeExe --version)）"

# ---------- 演示模式环境变量 ----------
New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null

$databasePath = Join-Path $dataDirectory "devflow-local-demo.db"
$databaseUrlPath = $databasePath.Replace("\", "/")
$env:DATABASE_URL = "sqlite:///$databaseUrlPath"
$env:MILVUS_ENABLED = "false"
$env:EMBEDDING_PROVIDER = "deterministic"
$env:EMBEDDING_MODEL = "deterministic-demo"
$env:EMBEDDING_DIMENSIONS = "128"
$env:AUTO_SYNC_ENABLED = "false"
$env:DEMO_MODE = "true"
$env:NEXT_PUBLIC_API_BASE_URL = "http://127.0.0.1:$BackendPort"
$env:PYTHONPATH = $backendDirectory

if (-not $UseConfiguredLLM) {
    $env:LLM_API_KEY = ""
    $env:RAG_LLM_ENABLED = "false"
    $env:RAGAS_ENABLED = "false"
}

$backendProcess = $null
$frontendProcess = $null

try {
    # ---------- 启动后端 ----------
    Write-Step "正在启动后端（端口 $BackendPort）..."
    $backendProcess = Start-Process `
        -FilePath $pythonPath `
        -ArgumentList @("-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$BackendPort") `
        -WorkingDirectory $backendDirectory `
        -RedirectStandardOutput $backendOutputLog `
        -RedirectStandardError $backendErrorLog `
        -WindowStyle Hidden `
        -PassThru

    $backendReady = $false
    for ($attempt = 0; $attempt -lt 60; $attempt += 1) {
        if ($backendProcess.HasExited) {
            throw "后端进程提前退出，请查看日志：$backendErrorLog"
        }
        if (Test-ServiceHealth "http://127.0.0.1:$BackendPort/health") {
            $backendReady = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $backendReady) {
        throw "后端在 30 秒内未就绪，请查看日志：$backendErrorLog"
    }
    Write-Step "后端已就绪。"

    # ---------- 初始化演示数据 ----------
    Write-Step "正在初始化演示数据..."
    Push-Location $backendDirectory
    try {
        & $pythonPath (Join-Path $projectRoot "scripts\seed_demo_data.py")
        if ($LASTEXITCODE -ne 0) {
            throw "演示数据初始化失败。"
        }
    }
    finally {
        Pop-Location
    }

    $demoRepositories = Invoke-RestMethod -Uri "http://127.0.0.1:$BackendPort/api/repos" -TimeoutSec 5
    $demoRepository = $demoRepositories | Where-Object { $_.full_name -eq "course-demo/devflow-sample-api" } | Select-Object -First 1
    if (-not $demoRepository) {
        throw "没有找到初始化后的演示仓库。"
    }
    Invoke-RestMethod `
        -Method Patch `
        -Uri "http://127.0.0.1:$BackendPort/api/rag/repositories/$($demoRepository.id)/config" `
        -ContentType "application/json" `
        -Body '{"retrieval_method":"hybrid","score_threshold_enabled":false}' `
        -TimeoutSec 10 | Out-Null

    # ---------- 启动前端 ----------
    Write-Step "正在启动前端（端口 $FrontendPort），首次编译约需 20-60 秒..."
    # 直接用 node.exe 调用 npm-cli.js，绕开 npm.cmd 在不同环境下的 Start-Process 兼容问题。
    # 路径可能含空格（如 DoubaoWork 的 User Data 目录），必须用内嵌双引号包裹成单个参数。
    $quotedNpmCli = "`"$npmCliPath`""
    $frontendProcess = Start-Process `
        -FilePath $nodeExe `
        -ArgumentList @($quotedNpmCli, "run", "dev", "--", "-p", "$FrontendPort") `
        -WorkingDirectory $frontendDirectory `
        -RedirectStandardOutput $frontendOutputLog `
        -RedirectStandardError $frontendErrorLog `
        -WindowStyle Hidden `
        -PassThru

    $frontendReady = $false
    for ($attempt = 0; $attempt -lt 120; $attempt += 1) {
        if ($frontendProcess.HasExited) {
            throw "前端进程提前退出，请查看日志：$frontendErrorLog"
        }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$FrontendPort" -TimeoutSec 2 | Out-Null
            $frontendReady = $true
            break
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $frontendReady) {
        throw "前端在 60 秒内未就绪，请查看日志：$frontendErrorLog"
    }

    # ---------- 记录 PID ----------
    $pidRecord = [ordered]@{
        backend_pid  = $backendProcess.Id
        frontend_pid = $frontendProcess.Id
        backend_port = $BackendPort
        frontend_port = $FrontendPort
        started_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    [IO.File]::WriteAllText($pidFilePath, ($pidRecord | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))

    Write-Host ""
    Write-Host "FlowPilot AI 启动成功！" -ForegroundColor Green
    Write-Host "  前端页面：http://127.0.0.1:$FrontendPort" -ForegroundColor Green
    Write-Host "  后端接口：http://127.0.0.1:$BackendPort" -ForegroundColor Green
    Write-Host "  接口文档：http://127.0.0.1:$BackendPort/docs" -ForegroundColor Green
    Write-Host "  后端 PID：$($backendProcess.Id)，前端 PID：$($frontendProcess.Id)"
    Write-Host "  运行日志：$dataDirectory"
    Write-Host "  停止服务：双击「一键停止.bat」" -ForegroundColor Yellow
    Write-Host "说明：当前为 SQLite 演示模式，向量检索显示 degraded 属正常现象。" -ForegroundColor DarkGray

    if (-not $NoBrowser) {
        Start-Process "http://127.0.0.1:$FrontendPort"
    }
}
catch {
    Write-Host "启动失败：$($_.Exception.Message)" -ForegroundColor Red
    if ($frontendProcess -and -not $frontendProcess.HasExited) {
        Stop-Process -Id $frontendProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($backendProcess -and -not $backendProcess.HasExited) {
        Stop-Process -Id $backendProcess.Id -Force -ErrorAction SilentlyContinue
    }
    throw
}

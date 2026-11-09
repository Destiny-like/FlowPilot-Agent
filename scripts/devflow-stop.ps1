<#
.SYNOPSIS
    停止由 devflow-start.ps1 启动的 FlowPilot AI 前后端进程（含子进程树）。
.DESCRIPTION
    仅停止确认属于本项目的进程：PID 文件记录的进程，或可执行路径/命令行指向本项目目录的进程。
    对 Docker、WSL 等非本项目进程一律跳过，不会误停其他程序。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$dataDirectory = Join-Path $projectRoot ".data"
$pidFilePath = Join-Path $dataDirectory "devflow-pids.json"
$normalizedRoot = $projectRoot.ToLower().TrimEnd('\')

function Stop-ProcessTree {
    param([int]$ProcessId)

    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

# 判断进程是否属于本项目：可执行路径或命令行指向项目目录。
function Test-ProcessBelongsToProject {
    param([int]$ProcessId)

    $wmiProc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if (-not $wmiProc) { return $false }

    $exePath = $wmiProc.ExecutablePath
    if ($exePath -and $exePath.ToLower().StartsWith("$normalizedRoot\")) {
        return $true
    }
    $cmdLine = $wmiProc.CommandLine
    if ($cmdLine -and $cmdLine.ToLower().Contains("$normalizedRoot\")) {
        return $true
    }
    return $false
}

# 1) 优先按 PID 文件停止本项目自己启动的进程
if (Test-Path -LiteralPath $pidFilePath -PathType Leaf) {
    try {
        $savedPids = Get-Content -LiteralPath $pidFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @("backend_pid", "frontend_pid")) {
            $targetPid = $savedPids.$name
            if ($targetPid -and (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
                Write-Host "[FlowPilot] 停止 $name（PID $targetPid）及其子进程..."
                Stop-ProcessTree -ProcessId ([int]$targetPid)
            }
        }
    }
    catch {
        Write-Host "[FlowPilot] 读取 PID 记录失败，将仅按进程归属做安全清理。" -ForegroundColor Yellow
    }
    Remove-Item -LiteralPath $pidFilePath -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host "[FlowPilot] 未找到 PID 记录文件，仅清理确认属于本项目的残留进程。" -ForegroundColor Yellow
}

# 2) 端口兜底：只停止确认属于本项目的监听进程，跳过 Docker/系统进程
Start-Sleep -Seconds 1
foreach ($port in @(3000, 8010)) {
    $connections = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($connection in $connections) {
        $ownerPid = $connection.OwningProcess
        if (-not $ownerPid) { continue }
        if (Test-ProcessBelongsToProject -ProcessId ([int]$ownerPid)) {
            Write-Host "[FlowPilot] 端口 $port 上的本项目进程（PID $ownerPid）执行停止。"
            Stop-ProcessTree -ProcessId ([int]$ownerPid)
        }
        else {
            $procName = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName
            Write-Host "[FlowPilot] 端口 $port 被其他程序（$procName，PID $ownerPid）占用，已跳过、不停止。" -ForegroundColor DarkYellow
        }
    }
}

# 3) 结果检查：区分“本项目残留”与“其他程序占用”
Start-Sleep -Seconds 1
$projectRemaining = $false
foreach ($port in @(3000, 8010)) {
    $connections = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($connection in $connections) {
        if (Test-ProcessBelongsToProject -ProcessId ([int]$connection.OwningProcess)) {
            Write-Host "[FlowPilot] 本项目进程仍占用端口 $port，请手动检查。" -ForegroundColor Red
            $projectRemaining = $true
        }
    }
}

if (-not $projectRemaining) {
    Write-Host "[FlowPilot] FlowPilot AI 已停止，本项目进程全部清理完毕。" -ForegroundColor Green
}

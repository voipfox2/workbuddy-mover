<#
  WorkBuddy 搬家器 —— 环境与数据目录切换脚本（逐用户版，环境变量方案）

  项目：WorkBuddy 搬家器        版本：v1.0.0        发布：2026-10-31
  版本历史见 README.md「版本记录」

  一次性处理两件事：
    1) 数据/缓存目录（默认 %USERPROFILE%\.workbuddy）
       -> 迁到该账户“系统用户目录”下的 .workbuddy
    2) 工作区目录（任务/项目所在，由 defaultWorkspacePath 决定，默认 <用户目录>\WorkBuddy）
       -> 迁到同一“系统用户目录”下，并改写 app-config.json 中的 defaultWorkspacePath

  “系统用户目录”通过 Desktop 已知文件夹反推（桌面/文档被重定向到 D:\Users\<用户名> 时，
  就落在 D:\Users\<用户名>），不写死任何用户名。

  用法（在“目标账户”下登录后执行）：
    # 数据 + 工作区一并迁移并设好环境变量（默认）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wb-switch-user-v1.0.0.ps1

    # 自动结束 WorkBuddy 进程后再迁移（-Yes 跳过确认；双击 bat 默认带 -KillRunning）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wb-switch-user-v1.0.0.ps1 -KillRunning

    # 连日志/缓存一起全量复制（默认会跳过 logs/traces/Cache 等可自动重建的目录）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wb-switch-user-v1.0.0.ps1 -KillRunning -FullCopy

    # 数据已就位、不复制任何文件，只切换环境变量（工作区路径配置仍会按需改写）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wb-switch-user-v1.0.0.ps1 -NoMigrate

    # 跳过工作区处理（只动数据目录）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wb-switch-user-v1.0.0.ps1 -NoWorkspace

    # 自定义目标目录（覆盖自动推断）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wb-switch-user-v1.0.0.ps1 -TargetDir "E:\data\wb" -WorkspaceTarget "E:\data\wb-workspace"

    # 回滚：仅清除本脚本写入的环境变量
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wb-switch-user-v1.0.0.ps1 -Rollback

  说明：
    - 必须先完全退出 WorkBuddy（含托盘）再执行；或加 -KillRunning 自动结束（双击 bat 默认如此）。
    - 复制为单遍 robocopy，控制台有百分比进度条（按已复制字节/总数换算），不会长时间无反馈。
    - 默认跳过 logs/traces/Cache/GPUCache/Crashpad 等可自动重建目录，减少复制量并避开占用失败；
      需要全量复制时加 -FullCopy。
    - robocopy 返回码 >=8 表示“有文件未复制成功”，脚本会列出这些文件并询问是否继续。
    - 环境变量写入当前用户的用户级作用域（HKCU），对“当前账户”生效；每个账户各自跑一次。
    - 旧目录不会被删除，验证后再自行改名收尾。
#>
[CmdletBinding()]
param(
    [string]$TargetDir = '',
    [string]$WorkspaceTarget = '',
    [switch]$NoMigrate,
    [switch]$NoWorkspace,
    [switch]$KillRunning,
    [switch]$Yes,
    [switch]$FullCopy,
    [switch]$Rollback
)

$ProjectName   = 'WorkBuddy 搬家器'
$ScriptVersion = '1.0.0'
$ErrorActionPreference = 'Stop'

Write-Host ($ProjectName + '  v' + $ScriptVersion + '  ·  wb-switch-user') -ForegroundColor DarkGray

# 当前账户信息
$UserName = $env:USERNAME
$Source   = Join-Path $env:USERPROFILE '.workbuddy'

# 推断“系统用户目录”：取 Desktop 已知文件夹的父目录
$desktopDir = [Environment]::GetFolderPath('Desktop')
if ($desktopDir -and (Test-Path -LiteralPath $desktopDir)) {
    $userDir = [System.IO.Directory]::GetParent($desktopDir).FullName
} else {
    $userDir = [System.IO.Directory]::GetParent($env:USERPROFILE).FullName
}
if (-not $TargetDir) {
    $TargetDir = Join-Path $userDir '.workbuddy'
}
if (-not $WorkspaceTarget) {
    $WorkspaceTarget = Join-Path $userDir 'WorkBuddy'
}

$EnvPairs = [ordered]@{
    'WORKBUDDY_CONFIG_DIR'    = $TargetDir
    'WORKBUDDY_USER_DATA_DIR' = Join-Path $TargetDir 'app'
    'WORKBUDDY_DATA_DIR'      = $TargetDir
    'CODEBUDDY_CONFIG_DIR'    = $TargetDir
}

$WbProcessNames = @('WorkBuddy', 'WorkBuddyRepair', 'workbuddy-editor-sdk-supervisor')
function Get-WbProcesses {
    @(Get-Process -Name $WbProcessNames -ErrorAction SilentlyContinue)
}
function Test-WbRunning {
    Get-WbProcesses
}
# 判断当前脚本是否运行在 WorkBuddy 自己的进程树内（此时结束 WorkBuddy 会连带杀掉本脚本）
function Test-InsideWorkBuddy {
    try {
        $procs = @{}
        Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { $procs[[int]$_.ProcessId] = $_ }
        $cur = $PID
        $guard = 0
        while ($procs.ContainsKey($cur) -and $guard -lt 25) {
            $p = $procs[$cur]
            if ($p.ProcessId -ne $PID -and $p.Name -match '^WorkBuddy') { return $true }
            $cur = [int]$p.ParentProcessId
            $guard++
        }
    } catch {}
    return $false
}
# 优雅关闭 -> 等待 -> 强制结束 -> 等待全部退出；返回 $true 表示已全部退出
function Stop-WbProcesses {
    $procs = Get-WbProcesses
    if (-not $procs) { return $true }
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch {} }
    Start-Sleep -Seconds 3
    $still = Get-WbProcesses
    if ($still) {
        foreach ($p in $still) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} }
    }
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-WbProcesses)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (-not (Get-WbProcesses))
}
function Write-Step($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Test-SamePath($a, $b) {
    if ($null -eq $a -or $null -eq $b) { return $false }
    try { return ([System.IO.Path]::GetFullPath($a).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($b).TrimEnd('\')) }
    catch { return ($a -ieq $b) }
}
function Get-ConfigPath {
    # 配置可能已在目标（已迁移）或源（尚未迁移）位置，取存在的那个
    $candidates = @(
        (Join-Path $TargetDir 'app\app-config.json'),
        (Join-Path $Source 'app\app-config.json')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
function Get-CurrentWorkspacePath {
    $cfg = Get-ConfigPath
    if ($cfg) {
        try {
            $json = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.defaultWorkspacePath -and $json.defaultWorkspacePath.Trim()) {
                return $json.defaultWorkspacePath.Trim()
            }
        } catch {}
    }
    # 回落：系统默认 <homedir>\WorkBuddy
    return (Join-Path $env:USERPROFILE 'WorkBuddy')
}
function Set-WorkspacePathInConfig($newPath) {
    $cfg = Get-ConfigPath
    if (-not $cfg) {
        Write-Host '  未找到 app-config.json，跳过写入 defaultWorkspacePath。' -ForegroundColor Yellow
        return
    }
    $json = $null
    try { $json = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if ($null -eq $json) { $json = [PSCustomObject]@{} }
    if (Test-SamePath $json.defaultWorkspacePath $newPath) {
        Write-Host ("  defaultWorkspacePath 已是 {0}，无需改动。" -f $newPath) -ForegroundColor Green
        return
    }
    $json.defaultWorkspacePath = $newPath
    $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cfg -Encoding UTF8
    Write-Host ("  已写入 defaultWorkspacePath = {0}" -f $newPath) -ForegroundColor Green
}

# 单遍复制 + 控制台进度条（按已复制字节/总数换算百分比）。
# 返回对象：Skipped / Code(robocopy退出码) / Files / Bytes / Log
function Copy-TreeWithProgress {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$Dst,
        [string[]]$ExcludeDirs = @(),
        [string]$Label = '复制'
    )

    if (-not (Test-Path -LiteralPath $Src)) {
        return [pscustomobject]@{ Skipped = $true; Code = 0; Files = 0; Bytes = 0; Log = $null }
    }
    if (-not (Test-Path -LiteralPath $Dst)) {
        New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    }

    Write-Host '  正在统计源文件...'
    $exList = @($ExcludeDirs | Where-Object { $_ })
    $allFiles = @(Get-ChildItem -LiteralPath $Src -Recurse -Force -File -ErrorAction SilentlyContinue)
    if ($exList.Count -gt 0) {
        $counted = @($allFiles | Where-Object {
            $fp = $_.FullName
            -not ($exList | Where-Object { $fp.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })
        })
    } else {
        $counted = $allFiles
    }
    $stat = $counted | Measure-Object -Property Length -Sum
    $totalFiles = [int]$stat.Count
    $totalBytes = [double]$stat.Sum
    Write-Host ("  源：文件 {0} 个，{1:N1} MB" -f $totalFiles, ($totalBytes / 1MB))

    $roboExe = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $logFile = Join-Path $env:TEMP ('wb-copy-{0}.log' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    $argList = @($Src, $Dst, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/R:1', '/W:1', '/MT:16',
                 '/NDL', '/NP', '/NJH', '/NJS', ('/LOG:{0}' -f $logFile))
    foreach ($d in $ExcludeDirs) { $argList += '/XD'; $argList += $d }

    $job = Start-Job -ScriptBlock {
        param($exe, $exeArgs)
        & $exe @exeArgs | Out-Null
        $LASTEXITCODE
    } -ArgumentList $roboExe, $argList

    $start = Get-Date
    while ($job.State -eq 'Running') {
        $ds = Get-ChildItem -LiteralPath $Dst -Recurse -Force -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum
        $doneB = [double]$ds.Sum
        $doneF = [int]$ds.Count
        $pct = 0
        if ($totalBytes -gt 0) { $pct = [int][math]::Min(100, [math]::Round(($doneB / $totalBytes) * 100)) }
        elseif ($totalFiles -gt 0) { $pct = [int][math]::Min(100, [math]::Round(($doneF / [double]$totalFiles) * 100)) }
        $elapsed = (Get-Date) - $start
        Write-Progress -Activity $Label `
            -Status ("{0:N0}/{1:N0} 文件  {2:N1}/{3:N1} MB  已用 {4:mm\:ss}" -f $doneF, $totalFiles, ($doneB / 1MB), ($totalBytes / 1MB), $elapsed) `
            -PercentComplete $pct
        Start-Sleep -Milliseconds 3000
    }

    $out = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Write-Progress -Activity $Label -Completed

    $code = 16
    $last = $out | Where-Object { $_ -is [int] } | Select-Object -Last 1
    if ($null -ne $last) { $code = [int]$last }

    return [pscustomobject]@{ Skipped = $false; Code = $code; Files = $totalFiles; Bytes = $totalBytes; Log = $logFile }
}

# 写环境变量后广播 WM_SETTINGCHANGE，让已运行的 Explorer 刷新环境块，
# 避免“脚本写对了、但从开始菜单启动的 WorkBuddy 仍读不到新变量”。
function Update-EnvironmentBroadcast {
    try {
        $type = $null
        try { $type = [WB.Win32EnvBroadcast] } catch {
            $sig = @'
[DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
            $type = Add-Type -MemberDefinition $sig -Name 'Win32EnvBroadcast' -Namespace 'WB' -PassThru
        }
        $HWND_BROADCAST = [IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x001A
        $SMTO_ABORTIFHUNG = 0x0002
        $result = [UIntPtr]::Zero
        [void]$type::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment', $SMTO_ABORTIFHUNG, 2000, [ref]$result)
        Write-Host '  已广播 WM_SETTINGCHANGE，通知 Explorer 刷新环境变量。' -ForegroundColor Green
    } catch {
        Write-Host '  广播环境变量变更失败（可忽略，重新登录后仍生效）。' -ForegroundColor Yellow
    }
}

# ---------- 回滚 ----------
if ($Rollback) {
    Write-Step '回滚：清除当前账户的用户级环境变量'
    foreach ($k in $EnvPairs.Keys) {
        $old = [Environment]::GetEnvironmentVariable($k, 'User')
        [Environment]::SetEnvironmentVariable($k, $null, 'User')
        Write-Host ("  {0}: {1} -> (已移除)" -f $k, $(if ($old) { $old } else { '(原本未设置)' }))
    }
    Write-Host "`n回滚完成（仅清除环境变量）。" -ForegroundColor Green
    Write-Host '若此前改过 defaultWorkspacePath，请按需在 WorkBuddy 设置里改回原值。' -ForegroundColor Yellow
    return
}

# ---------- 前置检查 ----------
Write-Step '当前账户与路径'
Write-Host ("  用户：{0}" -f $UserName)
Write-Host ("  默认源（数据目录）：{0}" -f $Source)
Write-Host ("  推断的系统用户目录：{0}" -f $userDir)
Write-Host ("  目标数据目录：{0}" -f $TargetDir)
Write-Host ("  目标工作区目录：{0}" -f $WorkspaceTarget)

if (Test-SamePath $TargetDir $Source) {
    Write-Host "`n目标数据目录与默认源相同，无需切换。" -ForegroundColor Yellow
    return
}

$running = Test-WbRunning
if ($running) {
    if (-not $KillRunning) {
        Write-Host ("`n检测到 WorkBuddy 进程未退出：PID {0}" -f ($running.Id -join ', ')) -ForegroundColor Red
        Write-Host '  可加参数 -KillRunning 让脚本自动结束这些进程后再迁移；' -ForegroundColor Yellow
        Write-Host '  或先由系统托盘右键 -> 退出，确认无 WorkBuddy.exe 后重跑。' -ForegroundColor Yellow
        exit 1
    }

    # 自保护：脚本若跑在 WorkBuddy 进程树内，结束 WorkBuddy 会连带杀掉本脚本，迁移做一半
    if (Test-InsideWorkBuddy) {
        Write-Host '检测到本脚本运行在 WorkBuddy 进程内部。若在此结束 WorkBuddy，会连同本脚本一起被杀，' -ForegroundColor Red
        Write-Host '迁移只做一半。请【直接双击 wb-switch-user-v1.0.0.bat】运行（进程挂在 Explorer 下，安全）。' -ForegroundColor Red
        exit 2
    }

    if (-not $Yes) {
        $ans = Read-Host ("即将结束 {0} 个 WorkBuddy 进程（WorkBuddy 会关闭）。继续请输 y" -f $running.Count)
        if ($ans -notmatch '^(y|yes|是)$') { Write-Host '已取消，未做任何更改。' -ForegroundColor Yellow; exit 1 }
    }

    Write-Step '结束 WorkBuddy 进程'
    Write-Host ("  目标：PID {0}" -f ($running.Id -join ', '))
    $ok = Stop-WbProcesses
    if (-not $ok) {
        $rem = Get-WbProcesses
        Write-Host ("  仍有进程未退出：PID {0}，已中止（未修改任何文件/变量）。" -f ($rem.Id -join ', ')) -ForegroundColor Red
        exit 1
    }
    Write-Host '  已全部退出，继续迁移。' -ForegroundColor Green
    Start-Sleep -Seconds 2
}

# ---------- 迁移数据目录（.workbuddy） ----------
if (-not $NoMigrate) {
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Step '源数据目录不存在，跳过复制'
        Write-Host ("  默认源 {0} 不存在（新账户或未迁移过）。仅创建目标并写入环境变量。" -f $Source)
        if (-not (Test-Path -LiteralPath $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
    } else {
        Write-Step ("复制数据目录到 " + $TargetDir)

        $excludes = @()
        if (-not $FullCopy) {
            foreach ($rel in @('logs', 'traces', 'cache', 'tmp', 'temp',
                               'app\Cache', 'app\Code Cache', 'app\GPUCache', 'app\DawnCache',
                               'app\ShaderCache', 'app\Crashpad', 'app\blob_storage')) {
                $excludes += (Join-Path $Source $rel)
            }
            Write-Host '  跳过日志/缓存类目录（自动重建、常被占用）：logs, traces, Cache, GPUCache, Crashpad ...' -ForegroundColor DarkGray
        }

        $r = Copy-TreeWithProgress -Src $Source -Dst $TargetDir -ExcludeDirs $excludes -Label '复制数据目录'

        if ($r.Code -ge 8) {
            Write-Host ("  robocopy 返回码 {0}：有文件未能复制（8 位=复制失败，常见于占用/超长路径/权限）。" -f $r.Code) -ForegroundColor Yellow
            if ($r.Log -and (Test-Path -LiteralPath $r.Log)) {
                $errs = Select-String -LiteralPath $r.Log -Pattern 'ERROR|错误|拒绝访问|Access is denied' -ErrorAction SilentlyContinue |
                        Select-Object -First 15
                if ($errs) {
                    Write-Host '  未能复制的文件（前 15 条）：' -ForegroundColor Yellow
                    foreach ($e in $errs) { Write-Host ('    ' + $e.Line.Trim()) -ForegroundColor DarkYellow }
                }
            }
            Write-Host '  这些通常是日志/缓存/占用文件，多为可自动重建，不影响使用。' -ForegroundColor Yellow
            if (-not $Yes) {
                $ans = Read-Host '  是否忽略这些文件继续（其余已复制）? 输 y 继续，其他键中止'
                if ($ans -notmatch '^(y|yes|是)$') {
                    Write-Host '  已中止，未修改环境变量。可重跑本脚本补齐剩余文件。' -ForegroundColor Red
                    exit 1
                }
            }
        } elseif ($r.Code -ge 1) {
            Write-Host ("  复制完成（robocopy 返回码 {0}，正常）。" -f $r.Code) -ForegroundColor Green
        } else {
            Write-Host '  复制完成（目标已是最新，无需复制）。' -ForegroundColor Green
        }
    }
} else {
    Write-Step '跳过数据目录复制（NoMigrate）'
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
}

# ---------- 迁移工作区目录（任务/项目） ----------
$wsSource = Get-CurrentWorkspacePath
Write-Step '工作环境（工作区目录）'
Write-Host ("  当前工作区路径：{0}" -f $wsSource)
Write-Host ("  目标工作区路径：{0}" -f $WorkspaceTarget)

if ($NoWorkspace) {
    Write-Host '  已指定 -NoWorkspace，跳过工作区处理（不改数据、不改配置）。' -ForegroundColor Yellow
} elseif (Test-SamePath $wsSource $WorkspaceTarget) {
    Write-Host '  源与目标相同（含大小写差异），无需复制。' -ForegroundColor Green
    # 仍确保配置指向该路径（通常已正确）
    Set-WorkspacePathInConfig $WorkspaceTarget
} else {
    if (-not (Test-Path -LiteralPath $wsSource)) {
        Write-Host ("  源工作区不存在：{0}，将仅创建目标并写入配置。" -f $wsSource) -ForegroundColor Yellow
        if (-not (Test-Path -LiteralPath $WorkspaceTarget)) {
            New-Item -ItemType Directory -Path $WorkspaceTarget -Force | Out-Null
        }
    } else {
        if (-not (Test-Path -LiteralPath $WorkspaceTarget)) {
            New-Item -ItemType Directory -Path $WorkspaceTarget -Force | Out-Null
        }
        Write-Step ("复制工作区到 " + $WorkspaceTarget)
        $r = Copy-TreeWithProgress -Src $wsSource -Dst $WorkspaceTarget -Label '复制工作区'
        if ($r.Code -ge 8) {
            Write-Host ("  工作区复制有文件未成功（robocopy 返回码 {0}），已继续，请自行核对。" -f $r.Code) -ForegroundColor Yellow
        } else {
            Write-Host '  工作区复制完成。' -ForegroundColor Green
        }
    }
    Set-WorkspacePathInConfig $WorkspaceTarget
}

# ---------- 目标目录汇总 ----------
if (-not $NoMigrate -and (Test-Path -LiteralPath $TargetDir)) {
    Write-Step '目标数据目录汇总'
    $dstStat = Get-ChildItem -LiteralPath $TargetDir -Recurse -Force -File -ErrorAction SilentlyContinue |
               Measure-Object -Property Length -Sum
    Write-Host ("  {0}" -f $TargetDir)
    Write-Host ("  已落盘：文件 {0:N0} 个，{1:N1} MB" -f $dstStat.Count, ($dstStat.Sum / 1MB))
}

# ---------- 设置环境变量 ----------
Write-Step '写入当前账户的用户级环境变量'
foreach ($k in $EnvPairs.Keys) {
    $old = [Environment]::GetEnvironmentVariable($k, 'User')
    [Environment]::SetEnvironmentVariable($k, $EnvPairs[$k], 'User')
    Write-Host ("  {0} = {1}   (原值: {2})" -f $k, $EnvPairs[$k], $(if ($old) { $old } else { '未设置' }))
}
Update-EnvironmentBroadcast

Write-Step '完成'
Write-Host @"

已为账户 [$UserName] 写入重定向：
  数据目录 -> $TargetDir
  工作区目录 -> $WorkspaceTarget

后续请手动完成：
  1) 环境变量已写入并广播刷新。为保险，建议先【注销并重新登录】一次
     （最可靠），再启动 WorkBuddy；或直接重开“文件资源管理器(Explorer)”后启动。
  2) 启动后确认：已登录、任务历史/插件/技能都在，且默认打开的工作区是上面的新位置；
     同时核对日志确在新目录产生：
       Get-ChildItem "$TargetDir\logs" | Sort-Object LastWriteTime -Descending | Select -First 3
  3) 确认无误后，把旧目录改名留观（数据目录、工作区目录各一个）：
       Rename-Item -LiteralPath "$Source" -NewName ".workbuddy.bak"
       Rename-Item -LiteralPath "$wsSource" -NewName "WorkBuddy.bak"
     观察 3-5 天再删除。
  4) 若异常（仍落在 C 盘、登录态丢失），先确认已注销重登录；仍异常则立即回滚并重启：
       powershell -NoProfile -ExecutionPolicy Bypass -File .\wb-switch-user-v1.0.0.ps1 -Rollback

提示：环境变量属于“当前账户”，每个 Windows 账户都要各自跑一次本脚本。
另外部分内部模块会回落到 %USERPROFILE%\.workbuddy，旧目录改名后可能被重新
建成一个小目录，属正常现象，不是切换失败。
"@ -ForegroundColor Green

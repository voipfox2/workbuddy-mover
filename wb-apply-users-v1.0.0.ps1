<#
  在【当前账户】下批量把其他本地账户的 WorkBuddy 数据目录重定向到指定位置，无需逐个登录。

  项目：WorkBuddy 搬家器        版本：v1.0.0        发布：2026-10-31
  版本历史见 README.md「版本记录」

  原理：以管理员身份临时加载目标账户的注册表配置单元 NTUSER.DAT，
        写入 HKEY_USERS\<临时名>\Environment 下的用户级环境变量，然后卸载。
        目标账户下次登录时生效，配置与登录态都留在各自目录，互不干扰。

  用法（必须管理员）：
    .\wb-apply-users-v1.0.0.ps1                                  预演：只列出将要做什么
    .\wb-apply-users-v1.0.0.ps1 -Apply                           真正写入（所有其他本地账户）
    .\wb-apply-users-v1.0.0.ps1 -Apply -Users <账户A>,<账户B>        只处理指定账户
    .\wb-apply-users-v1.0.0.ps1 -Apply -Migrate                  同时把各账户现有 数据目录 + 工作区 复制到新位置
    .\wb-apply-users-v1.0.0.ps1 -Apply -NoWorkspace              只改数据目录，不碰工作区
    .\wb-apply-users-v1.0.0.ps1 -Apply -WorkspaceRoot E:\WB      工作区放到其它盘
    .\wb-apply-users-v1.0.0.ps1 -Verify                          只读校验：查看各账户当前 4 个变量的实际值
    .\wb-apply-users-v1.0.0.ps1 -Rollback                        撤销：清除这些账户里的 4 个变量

  处理内容（每个账户）：
    1. 数据目录  <TargetRoot>\<账户>\.workbuddy                        （靠 4 个环境变量重定向）
    2. 工作区    <WorkspaceRoot 或 TargetRoot>\<账户>\WorkBuddy        （靠 app-config.json 的 defaultWorkspacePath）
       —— 程序默认取 homedir()\WorkBuddy，对其他账户就是 C:\Users\<账户>\WorkBuddy，
          不改配置的话工作区仍然堆在 C 盘。

  写入的变量（与当前账户迁移脚本一致）：
    WORKBUDDY_CONFIG_DIR / WORKBUDDY_USER_DATA_DIR / WORKBUDDY_DATA_DIR / CODEBUDDY_CONFIG_DIR
#>
[CmdletBinding()]
param(
    [string[]]$Users,
    [string]$TargetRoot = 'D:\Users',
    [string]$WorkspaceRoot,
    [switch]$NoWorkspace,
    [switch]$Migrate,
    [switch]$DeleteSourceAfterMigrate,
    [switch]$IncludeDefaultProfile,
    [switch]$Verify,
    [switch]$Apply,
    [switch]$Rollback
)

$ProjectName   = 'WorkBuddy 搬家器'
$ScriptVersion = '1.0.0'
$ErrorActionPreference = 'Stop'

Write-Host ($ProjectName + '  v' + $ScriptVersion + '  ·  wb-apply-users') -ForegroundColor DarkGray

$VarNames = @('WORKBUDDY_CONFIG_DIR', 'WORKBUDDY_USER_DATA_DIR', 'WORKBUDDY_DATA_DIR', 'CODEBUDDY_CONFIG_DIR')

function Write-Step([string]$t) {
    Write-Host ''
    Write-Host ("=== " + $t + " ===") -ForegroundColor Cyan
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LocalProfiles {
    # 用 Win32_UserProfile 枚举：能直接拿到 LocalPath / SID / 是否已加载
    $res = @()
    foreach ($u in (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue)) {
        if (-not $u.LocalPath) { continue }
        if ($u.Special -eq $true) { continue }
        if ($u.SID -match '^S-1-5-(18|19|20)$') { continue }
        $res += [pscustomobject]@{
            SID    = $u.SID
            Name   = (Split-Path $u.LocalPath -Leaf)
            Path   = $u.LocalPath
            Loaded = [bool]$u.Loaded
        }
    }
    return $res
}

function Invoke-Icacls {
    # 包装 icacls：原生命令写 stderr 时，脚本级 $ErrorActionPreference='Stop' 会抛 NativeCommandError
    # 直接中断整个流程，这里临时降级并把输出收集起来自己判断。
    param([string[]]$IArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & icacls @IArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Code = $code; Text = (($out | ForEach-Object { "$_" }) -join "`n") }
}

function Grant-Modify([string]$Dir, [string]$Account, [switch]$Recurse) {
    # 管理员创建的目录默认不授予目标账户写权限，必须补一条 ACL，否则对方登录后无法写入。
    # 默认【不递归】：对账户根目录递归会闯进 INetCache\Content.IE5 等系统保护目录而被拒绝。
    # (OI)(CI) 表示对象继承 + 容器继承，新的和已有的子项都会自动继承这条 ACE，无需 /T。
    if (-not (Test-Path -LiteralPath $Dir -ErrorAction SilentlyContinue)) { return $false }
    $a = @($Dir, '/grant', "$($Account):(OI)(CI)M", '/Q', '/C')
    if ($Recurse) { $a += '/T' }
    $r = Invoke-Icacls -IArgs $a
    if ($r.Code -eq 0) { return $true }

    # 递归模式遇到少量受保护/占用子目录会返回非 0，但只要 ACE 已落到根上就算达到目的。
    # 注意：不能用 icacls 输出文本里是否含账户名来判断——路径本身也含账户名，会误判。
    if ((Test-HasAce -Dir $Dir -Account $Account)) { return $true }
    Write-Host ('    授权未完全成功（icacls 退出码 ' + $r.Code + '）：' + $Dir) -ForegroundColor Yellow
    Write-Host ('      详情：' + (($r.Text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' | ')) -ForegroundColor DarkGray
    return $false
}

function Test-HasAce([string]$Dir, [string]$Account) {
    try {
        $acl = Get-Acl -LiteralPath $Dir -ErrorAction Stop
        $hit = @($acl.Access | Where-Object {
            $_.IdentityReference -and ($_.IdentityReference.Value -match ('\\' + [regex]::Escape($Account) + '$'))
        })
        return ($hit.Count -gt 0)
    } catch {
        return $false
    }
}

function Get-ConfiguredWorkspace([string]$DataDir) {
    # 从某个数据目录的 app\app-config.json 读 defaultWorkspacePath
    $cfg = Join-Path $DataDir 'app\app-config.json'
    if (-not (Test-Path -LiteralPath $cfg -ErrorAction SilentlyContinue)) { return $null }
    try {
        $j = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        if ($j.defaultWorkspacePath) { return [string]$j.defaultWorkspacePath }
    } catch { }
    return $null
}

function Set-ConfiguredWorkspace([string]$DataDir, [string]$Path) {
    # 写入 defaultWorkspacePath：保留其它键，且必须写成 UTF-8 无 BOM（Node 的 JSON.parse 不认 BOM）
    $appDir = Join-Path $DataDir 'app'
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    $cfg = Join-Path $appDir 'app-config.json'
    $obj = $null
    if (Test-Path -LiteralPath $cfg -ErrorAction SilentlyContinue) {
        try { $obj = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { $obj = $null }
    }
    if ($null -eq $obj) { $obj = [pscustomobject]@{} }
    if ($obj.PSObject.Properties.Name -contains 'defaultWorkspacePath') {
        $obj.defaultWorkspacePath = $Path
    } else {
        $obj | Add-Member -NotePropertyName 'defaultWorkspacePath' -NotePropertyValue $Path -Force
    }
    $json = $obj | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($cfg, $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-WorkspaceTarget([string]$Account) {
    # 工作区目标：<WorkspaceRoot 或 TargetRoot>\<账户>\WorkBuddy
    $root = if ($WorkspaceRoot) { $WorkspaceRoot } else { $TargetRoot }
    return (Join-Path (Join-Path $root $Account) 'WorkBuddy')
}

function Copy-PlainTree([string]$Src, [string]$Dst) {
    # 工作区用：不做任何目录排除，原样复制
    New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    $rbArgs = @($Src, $Dst, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/R:1', '/W:1',
                '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
    & robocopy @rbArgs | Out-Null
    return $LASTEXITCODE
}

function Copy-Tree([string]$Src, [string]$Dst) {
    if (-not (Test-Path -LiteralPath $Src)) { return -1 }
    New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    $rbArgs = @($Src, $Dst, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/R:1', '/W:1',
                '/NFL', '/NDL', '/NP', '/NJH', '/NJS',
                '/XD', (Join-Path $Src 'logs'), (Join-Path $Src 'traces'), (Join-Path $Src 'cache'),
                (Join-Path $Src 'app\Cache'), (Join-Path $Src 'app\Code Cache'),
                (Join-Path $Src 'app\GPUCache'), (Join-Path $Src 'app\Crashpad'))
    & robocopy @rbArgs | Out-Null
    return $LASTEXITCODE
}

function Invoke-WithHive([string]$HiveFile, [string]$HiveName, [scriptblock]$Action) {
    # 返回 $true 表示成功加载并执行完毕；失败原因写入 $script:LastHiveError
    $script:LastHiveError = ''
    $out = & reg load "HKU\$HiveName" "$HiveFile" 2>&1
    if ($LASTEXITCODE -ne 0) {
        $script:LastHiveError = ($out | Out-String).Trim()
        return $false
    }
    try {
        & $Action
    } finally {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        & reg unload "HKU\$HiveName" 2>&1 | Out-Null
    }
    return $true
}

# ---------- 前置检查 ----------
# 预演不需要管理员；写入/回滚/校验（需读对方注册表）才需要
if (($Apply -or $Rollback -or $Verify) -and -not (Test-Admin)) {
    Write-Host ''
    Write-Host '需要管理员权限才能读取/修改其他账户。' -ForegroundColor Red
    Write-Host '请右键 wb-apply-users-v1.0.0.bat -> 以管理员身份运行；' -ForegroundColor Yellow
    Write-Host '或以管理员身份打开 PowerShell 后执行本脚本。' -ForegroundColor Yellow
    exit 3
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name.Split('\')[-1]
Write-Step '账户与目标'
Write-Host ("当前账户：{0}" -f $me)
Write-Host ("目标根目录：{0}（每个账户 -> {1}\<账户>\ .workbuddy）" -f $TargetRoot, $TargetRoot)

$profiles = Get-LocalProfiles | Where-Object { $_.Name -ne $me -and $_.Name -ne 'Public' -and $_.Name -ne 'Default' }
if ($Users) {
    $profiles = $profiles | Where-Object { $Users -contains $_.Name }
    if (-not $profiles) {
        Write-Host ("指定的账户在本机找不到：{0}" -f ($Users -join ', ')) -ForegroundColor Red
        exit 1
    }
}

$plan = @()
foreach ($p in $profiles) {
    $target = Join-Path (Join-Path $TargetRoot $p.Name) '.workbuddy'
    $src = Join-Path $p.Path '.workbuddy'
    $wsTarget = Get-WorkspaceTarget $p.Name
    $plan += [pscustomobject]@{
        账户     = $p.Name
        配置文件 = $p.Path
        数据目录 = $target
        工作区   = $(if ($NoWorkspace) { '(跳过)' } else { $wsTarget })
        现有数据 = $(if (Test-Path -LiteralPath $src -ErrorAction SilentlyContinue) { '有' } elseif (Test-Admin) { '无' } else { '未知(需管理员)' })
        已登录   = $(if ($p.Loaded) { '是（需先注销）' } else { '否' })
    }
}
if ($IncludeDefaultProfile) {
    $plan += [pscustomobject]@{
        账户 = 'Default(新建账户模板)'; 配置文件 = 'C:\Users\Default'
        数据目录 = (Join-Path (Join-Path $TargetRoot '<新账户>') '.workbuddy')
        工作区   = (Join-Path (Join-Path $TargetRoot '<新账户>') 'WorkBuddy')
        现有数据 = '-'; 已登录 = '-'
    }
}
$plan | Format-Table -AutoSize

if (-not $Apply -and -not $Rollback -and -not $Verify) {
    Write-Host '以上为预演结果，未做任何修改。确认无误后加 -Apply 执行。' -ForegroundColor Yellow
    Write-Host '示例：.\wb-apply-users-v1.0.0.ps1 -Apply' -ForegroundColor Yellow
    exit 0
}

# ---------- 执行 ----------
$done = 0; $skipped = 0; $failed = @()

foreach ($p in $profiles) {
    Write-Step ("处理账户 " + $p.Name)
    $hvName = 'WBTMP_' + ($p.Name -replace '[^A-Za-z0-9]', '_')
    $hiveFile = Join-Path $p.Path 'NTUSER.DAT'

    if (-not (Test-Path -LiteralPath $hiveFile -ErrorAction SilentlyContinue)) {
        Write-Host ("  找不到 {0}，跳过。" -f $hiveFile) -ForegroundColor Yellow
        $skipped++; continue
    }
    if (Test-Path ("Registry::HKEY_USERS\" + $p.SID) -ErrorAction SilentlyContinue) {
        Write-Host '  该账户当前已登录（注册表已加载），无法安全修改。' -ForegroundColor Yellow
        Write-Host '  请让该账户注销后再执行本脚本。' -ForegroundColor Yellow
        $skipped++; continue
    }

    $target = Join-Path (Join-Path $TargetRoot $p.Name) '.workbuddy'
    $envKey = "Registry::HKEY_USERS\$hvName\Environment"

    # ---------- 只读校验模式 ----------
    if ($Verify) {
        $okv = Invoke-WithHive -HiveFile $hiveFile -HiveName $hvName -Action {
            Write-Host '  该账户当前的 4 个变量：'
            foreach ($n in $VarNames) {
                $v = (Get-ItemProperty -Path $envKey -Name $n -ErrorAction SilentlyContinue).$n
                if ($v) { Write-Host ("    {0} = {1}" -f $n, $v) -ForegroundColor Green }
                else    { Write-Host ("    {0} = (未设置)" -f $n) -ForegroundColor Yellow }
            }
            $cfgv = Join-Path $target 'app\app-config.json'
            if (Test-Path -LiteralPath $cfgv -ErrorAction SilentlyContinue) {
                try {
                    $jv = Get-Content -LiteralPath $cfgv -Raw -Encoding UTF8 | ConvertFrom-Json
                    Write-Host ("    defaultWorkspacePath = {0}" -f $(if ($jv.defaultWorkspacePath) { $jv.defaultWorkspacePath } else { '(未设置)' }))
                } catch { Write-Host '    defaultWorkspacePath = (配置文件解析失败)' -ForegroundColor Yellow }
            } else {
                Write-Host ('    目标配置文件尚未生成：{0}' -f $cfgv)
            }
        }
        if (-not $okv) {
            Write-Host ('  读取失败：' + $script:LastHiveError) -ForegroundColor Red
            $failed += $p.Name
        } else { $done++ }
        continue
    }

    $ok = Invoke-WithHive -HiveFile $hiveFile -HiveName $hvName -Action {
        if (-not (Test-Path $envKey)) { New-Item -Path $envKey -Force | Out-Null }

        if ($Rollback) {
            foreach ($n in $VarNames) {
                $old = (Get-ItemProperty -Path $envKey -Name $n -ErrorAction SilentlyContinue).$n
                if ($null -ne $old) {
                    Remove-ItemProperty -Path $envKey -Name $n -Force -ErrorAction SilentlyContinue
                    Write-Host ("  已清除 {0}（原值 {1}）" -f $n, $old) -ForegroundColor Green
                }
            }
        } else {
            $map = @{
                'WORKBUDDY_CONFIG_DIR'    = $target
                'WORKBUDDY_USER_DATA_DIR' = (Join-Path $target 'app')
                'WORKBUDDY_DATA_DIR'      = $target
                'CODEBUDDY_CONFIG_DIR'    = $target
            }
            foreach ($n in $map.Keys) {
                $old = (Get-ItemProperty -Path $envKey -Name $n -ErrorAction SilentlyContinue).$n
                New-ItemProperty -Path $envKey -Name $n -Value $map[$n] -PropertyType String -Force | Out-Null
                Write-Host ("  {0} = {1}   (原值: {2})" -f $n, $map[$n], $(if ($old) { $old } else { '未设置' }))
            }
        }
    }

    if (-not $ok) {
        Write-Host ('  加载注册表配置单元失败（源：' + $hiveFile + '）') -ForegroundColor Yellow
        Write-Host ('  错误详情：' + $script:LastHiveError) -ForegroundColor Red
        Write-Host '  常见原因：未以管理员运行 / 该账户仍登录/有程序占用 / NTUSER.DAT 权限不足。' -ForegroundColor Yellow
        $failed += $p.Name; continue
    }

    if (-not $Rollback) {
        # 迁移现有数据（可选）
        if ($Migrate) {
            $src = Join-Path $p.Path '.workbuddy'
            if ((Test-Path -LiteralPath $src -ErrorAction SilentlyContinue) -and ((Resolve-Path $src).Path -ne (Resolve-Path $target -ErrorAction SilentlyContinue).Path)) {
                Write-Host ('  复制现有数据 -> ' + $target)
                $code = Copy-Tree -Src $src -Dst $target
                if ($code -ge 8) {
                    Write-Host ("  robocopy 返回 {0}，存在未复制文件（可稍后手动补齐）。" -f $code) -ForegroundColor Yellow
                } else {
                    Write-Host '  复制完成。' -ForegroundColor Green
                }
                if ($DeleteSourceAfterMigrate) {
                    Write-Host '  删除源目录 ...'
                    try { Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction Stop; Write-Host '  源目录已删除。' -ForegroundColor Green }
                    catch { Write-Host ('  源目录删除失败（可能有占用）：' + $_.Exception.Message) -ForegroundColor Yellow }
                }
            } else {
                Write-Host '  无现有数据可迁移（或源=目标），跳过复制。'
            }
        }

        # 目标目录与权限（非递归：递归整个账户根目录会撞上 INetCache\Content.IE5 等系统保护目录）
        $acctRoot = Join-Path $TargetRoot $p.Name
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $target 'app') -Force | Out-Null
        $g1 = Grant-Modify -Dir $acctRoot -Account $p.Name   # 父目录只授权本身（递归会撞 INetCache 等系统保护目录）
        $g2 = Grant-Modify -Dir $target -Account $p.Name -Recurse  # 自己的数据目录内部可安全递归
        if ($g1 -and $g2) {
            Write-Host ("  数据目录已就绪并已授予 {0} 修改权限：{1}" -f $p.Name, $target) -ForegroundColor Green
        } else {
            Write-Host ("  数据目录已建立：{0}" -f $target) -ForegroundColor Yellow
            Write-Host ("  [注意] ACL 授权未全部成功（父目录={0} / 数据目录={1}）。" -f $g1, $g2) -ForegroundColor Yellow
            Write-Host ("         该账户登录后若无法写入，请手动执行：" ) -ForegroundColor Yellow
            Write-Host ("         icacls `"{0}`" /grant `"{1}:(OI)(CI)M`"" -f $acctRoot, $p.Name) -ForegroundColor DarkGray
            Write-Host ("         icacls `"{0}`" /grant `"{1}:(OI)(CI)M`"" -f $target, $p.Name) -ForegroundColor DarkGray
        }

        # ---------- 工作区目录 ----------
        # 程序里 getSystemDefaultWorkspaceRoot() = homedir()\WorkBuddy，
        # 对其他账户就是 C:\Users\<账户>\WorkBuddy（仍在 C 盘），
        # 因此必须把 defaultWorkspacePath 写进 app-config.json 覆盖掉。
        if (-not $NoWorkspace) {
            $wsTarget = Get-WorkspaceTarget $p.Name
            $srcData = Join-Path $p.Path '.workbuddy'
            $wsSource = Get-ConfiguredWorkspace $srcData
            if (-not $wsSource) { $wsSource = Join-Path $p.Path 'WorkBuddy' }

            Write-Host ("  工作区：{0}  ->  {1}" -f $wsSource, $wsTarget)

            if ($Migrate -and (Test-Path -LiteralPath $wsSource -ErrorAction SilentlyContinue)) {
                if ($wsSource.TrimEnd('\') -ne $wsTarget.TrimEnd('\')) {
                    Write-Host '    复制工作区内容 ...'
                    $wc = Copy-PlainTree -Src $wsSource -Dst $wsTarget
                    if ($wc -ge 8) {
                        Write-Host ("    robocopy 返回 {0}，部分文件未复制。" -f $wc) -ForegroundColor Yellow
                    } else {
                        Write-Host '    工作区复制完成。' -ForegroundColor Green
                    }
                } else {
                    Write-Host '    工作区源=目标，跳过复制。'
                }
            } elseif (-not $Migrate) {
                Write-Host '    未指定 -Migrate：只建空目录并改配置，不搬旧文件。'
            }

            New-Item -ItemType Directory -Path $wsTarget -Force | Out-Null
            if (-not (Grant-Modify -Dir $wsTarget -Account $p.Name -Recurse)) {
                Write-Host ("    [注意] 工作区 ACL 未授权成功，可手动执行：icacls `"{0}`" /grant `"{1}:(OI)(CI)M`"" -f $wsTarget, $p.Name) -ForegroundColor Yellow
            }
            Set-ConfiguredWorkspace -DataDir $target -Path $wsTarget
            Write-Host ("    已写入 defaultWorkspacePath = {0}" -f $wsTarget) -ForegroundColor Green
        }
    } else {
        # 回滚：清空 defaultWorkspacePath，恢复成程序默认（homedir()\WorkBuddy）
        $cfg = Join-Path $target 'app\app-config.json'
        if (Test-Path -LiteralPath $cfg -ErrorAction SilentlyContinue) {
            try {
                Set-ConfiguredWorkspace -DataDir $target -Path ''
                Write-Host '  已清空 defaultWorkspacePath（恢复程序默认工作区）。' -ForegroundColor Green
            } catch {
                Write-Host ('  清空 defaultWorkspacePath 失败：' + $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    }

    $done++
}

# 新建账户模板
if ($IncludeDefaultProfile -and -not $Rollback) {
    Write-Step '处理 Default（新建账户模板）'
    $defHive = 'C:\Users\Default\NTUSER.DAT'
    $tplTarget = Join-Path $TargetRoot '<账户名>\.workbuddy'
    Write-Host ("  模板将写入：{0}" -f $tplTarget) -ForegroundColor Yellow
    Write-Host '  注意：模板里无法使用变量，只能写固定路径；如需对以后的新账户生效，' -ForegroundColor Yellow
    Write-Host '  建议直接修改映像/部署脚本，而不是改 Default 模板（路径里没有账户名会冲突）。' -ForegroundColor Yellow
    Write-Host '  因此本脚本默认不写 Default，仅提示。' -ForegroundColor Yellow
}

Write-Step '完成'
Write-Host ("  已处理 {0} 个账户，跳过 {1} 个。" -f $done, $skipped)
if ($failed.Count) { Write-Host ("  失败: " + ($failed -join ', ')) -ForegroundColor Red }

Write-Host ''
Write-Host '后续：' -ForegroundColor Cyan
Write-Host '  1) 目标账户下次登录时环境变量生效（无需重启，注销/登录即可）。'
Write-Host '  2) 工作区已改：首次以该账户启动 WorkBuddy，默认打开的目录就是上面的新位置。'
Write-Host '     若该账户之前用过，历史任务记录里的旧路径会失效（可重新打开新位置的文件夹）。'
Write-Host '  3) 数据目录为全新初始化时，登录态/插件需重新生成；带 -Migrate 则会带过来。'
Write-Host '  4) 想回滚：.\wb-apply-users-v1.0.0.ps1 -Rollback -Users <账户名>'

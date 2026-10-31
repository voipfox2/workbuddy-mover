# WorkBuddy 搬家器 v1.0.0

[![version](https://img.shields.io/badge/version-v1.0.0-blue.svg)](https://github.com/voipfox2/workbuddy-mover) [![license](https://img.shields.io/github/license/voipfox2/workbuddy-mover.svg)](https://github.com/voipfox2/workbuddy-mover/blob/main/LICENSE) [![platform](https://img.shields.io/badge/platform-Windows-0078D6.svg)](#) [![powershell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](#)

把 WorkBuddy 的数据目录与工作区从 C 盘搬到 D 盘（或其他盘）的脚本工具集。

当前版本：**v1.0.0**（2026-10-31）　·　版本历史见文末「八、版本记录」

## 一、目的与要解决的问题

WorkBuddy 默认把大量数据写在 **C 盘用户目录**下。随着使用时间变长，
数据库、插件、自下载运行时、技能、日志、缓存会持续膨胀，挤占系统盘空间，
也可能拖慢系统盘所在的那块磁盘。

本脚本集解决的核心问题是：**把 WorkBuddy 占空间的数据从 C 盘挪到 D 盘（或其他盘）**，
同时保证程序在迁移后仍能正常工作、用户原有的任务记录不丢失。

它要处理两类完全不同的目录，二者机制独立、互不牵连：

| 目录 | 默认位置 | 存放内容 | 重定向靠什么 |
|---|---|---|---|
| **数据目录** | `%USERPROFILE%\.workbuddy` | 数据库、插件、运行时、技能、日志、缓存 | 4 个用户级环境变量 |
| **工作区目录** | `%USERPROFILE%\WorkBuddy` | 任务 / 会话 / 项目文件夹 | `app\app-config.json` 的 `defaultWorkspacePath` |

只改环境变量，工作区仍留在 C 盘；只改配置文件，数据仍留在 C 盘。
因此一套完整的重定向必须**同时处理这两处**，脚本也正是围绕这一点设计。

## 二、原理（理论）

### 1. 数据目录靠环境变量

WorkBuddy 在启动早期读取以下 4 个变量来决定数据根目录的位置：

```
WORKBUDDY_CONFIG_DIR     = <目标>\.workbuddy          # 数据根目录
WORKBUDDY_USER_DATA_DIR  = <目标>\.workbuddy\app      # Electron userData
WORKBUDDY_DATA_DIR       = <目标>\.workbuddy          # 本地模型
CODEBUDDY_CONFIG_DIR     = <目标>\.workbuddy          # 子进程 CLI 配置根
```

这些变量属于**用户级环境变量**，写入后对该账户的所有进程生效。
因为数据根位置由程序在启动时读取，所以：

- 变量要**下次登录**才可靠生效（已运行的进程不会自动拿到新变量）；
- 一旦生效，程序就会去新目录读写，旧目录不再作为主目录。

### 2. 工作区靠配置文件

工作区是用户新建任务时默认打开的文件夹，位置由
`<数据目录>\app\app-config.json` 里的 `defaultWorkspacePath` 决定。
这个值是**文件路径字符串**，改它就把默认工作区指向 D 盘，与数据目录解耦。

### 3. 跨账户写入的原理

Windows 的用户级环境变量和 `defaultWorkspacePath` 都存放在**账户自己的注册表 / 配置**里。
要给「其他尚未登录的账户」设置这些，脚本以管理员身份**临时加载该账户的
`NTUSER.DAT` 注册表配置单元**，写入属于它自己的那份变量与配置，再卸载。
每个账户各持一份独立配置，互不共享数据库。

### 4. 目录权限的原理

管理员（或其他账户）在新位置建好目录后，目标账户默认**没有写权限**（目录创建者才是所有者）。
必须再对该目录补一条 ACL（访问控制条目），授予目标账户 **Modify（修改）** 权限，
否则对方登录后无法写入自己的数据。权限通过 `icacls` 设置，并靠
`(OI)(CI)`（对象继承 / 容器继承）让新建的子目录自动继承，从而无需对整棵目录树递归授权。

## 三、文件结构

文件名中的 `-v1.0.0` 即版本号，**脚本与启动器同名同版本**。

| 文件 | 类型 | 作用 | 适用场景 |
|---|---|---|---|
| `wb-switch-user-v1.0.0.ps1` | 主脚本 | 给**当前登录的这个账户**切换目录 | 你在某个账户下改自己的目录 |
| `wb-switch-user-v1.0.0.bat` | 启动器 | 双击即可运行，自动带 `-KillRunning` | 不想敲命令时使用 |
| `wb-apply-users-v1.0.0.ps1` | 主脚本 | 以管理员身份批量改**其他账户** | 给 `<账户A>` / `<账户B>` 这类账户改，无需逐个登录 |
| `wb-apply-users-v1.0.0.bat` | 启动器 | 不带参时为**预演**（只列计划不改写） | 先看计划，或执行 `-Verify` / `-Rollback` |
| `wb-apply-users-apply-v1.0.0.bat` | 启动器 | 自带 `-Apply` **直接写入** | 确认计划后的真正执行 |

> `.bat` 与同版本 `.ps1` 必须放在同一目录；bat 用 `%~dp0` 定位 ps1，移动时一起带走。
> 启动器内写死了对应版本号的 ps1 文件名，**升级版本时 bat 必须同步改**。

## 四、各脚本功能与解决的问题

### wb-switch-user —— 改当前账户

**解决的问题**：把自己正在用的账户的数据目录和工作区从 C 盘迁到 D 盘，
同时把旧数据带过去，避免重新登录、重新下载插件。

**行为**：
1. 自动按当前登录账户推断目标目录（取桌面父目录作为用户目录）；
2. 结束正在运行的 WorkBuddy 进程（避免复制半成品数据库）；
3. 把旧数据复制到新位置（带进度条，默认跳过日志 / 缓存等可再生目录）；
4. 写入 4 个环境变量，广播 `WM_SETTINGCHANGE` 通知系统刷新；
5. 改写 `defaultWorkspacePath` 指向新工作区。

**关键参数**：

| 参数 | 作用 |
|---|---|
| `-KillRunning` | 自动结束 WorkBuddy 进程（双击 bat 默认带） |
| `-TargetDir` / `-WorkspaceTarget` | 手动覆盖自动推断的目标路径 |
| `-NoMigrate` | 只改环境变量与配置，不复制文件（文件已就位时） |
| `-NoWorkspace` | 完全不碰工作区，只处理数据目录 |
| `-FullCopy` | 连日志、缓存一起复制 |
| `-Rollback` | 清掉本账户写入的 4 个环境变量 |

> 不能在 WorkBuddy 内置终端里运行——脚本会检测到自己处于 WorkBuddy 进程树内而拒绝执行，
> 否则会连同当前会话一起终止。

### wb-apply-users —— 批量改其他账户

**解决的问题**：不用逐个登录其他账户，就能为它们统一设置数据目录和工作区重定向；
适合一台机器上多个用户共享、统一把数据挪到 D 盘的场景。

**行为**（每个账户依次处理）：
1. 加载该账户的 `NTUSER.DAT`；
2. 写入属于它的 4 个环境变量与 `defaultWorkspacePath`；
3. 在目标盘建好目录并授予该账户 Modify 权限；
4. 可选：把对方 C 盘已有的旧数据迁移过来（否则为全新初始化）；
5. 卸载注册表配置单元。

**关键参数**：

| 参数 | 作用 |
|---|---|
| `-Apply` | 真正写入（不带则为预演，只列计划） |
| `-Verify` | 只读校验，打印各账户当前变量实际值 |
| `-Users <账户A>,<账户B>` | 限定账户；不给则是所有其他本地账户 |
| `-TargetRoot` / `-WorkspaceRoot` | 设置目标根目录，默认 `D:\Users` |
| `-Migrate` | 复制对方 C 盘现有的 `.workbuddy` 与 `WorkBuddy` |
| `-DeleteSourceAfterMigrate` | 迁移后删除源目录（谨慎） |
| `-NoWorkspace` | 不处理工作区 |
| `-IncludeDefaultProfile` | 连「新建账户」模板一起改 |
| `-Rollback` | 清变量 + 清空 `defaultWorkspacePath` |

## 五、使用方式

- **改自己的账户**：双击 `wb-switch-user-v1.0.0.bat`。
- **改其他账户**：先右键 `wb-apply-users-v1.0.0.bat` → 以管理员身份运行（看预演），
  确认无误后用 `wb-apply-users-apply-v1.0.0.bat` 以管理员身份真正执行。
- 直接调用脚本时，控制台首行会打印 `脚本名 + 版本号`，便于确认跑的是哪个版本。

## 六、回滚

```powershell
# 自己的账户：只清环境变量，不动文件
.\wb-switch-user-v1.0.0.ps1 -Rollback

# 其他账户：清环境变量 + 清空 defaultWorkspacePath
.\wb-apply-users-v1.0.0.ps1 -Rollback -Users <账户A>
```

回滚后 WorkBuddy 回到原来的 C 盘路径；若旧目录已被删除，则需重新初始化。

## 七、生效判定

- 目标账户**注销后重新登录**，环境变量即生效，无需重启机器。
- 不登录对方账户也能验证：
  1. 目标目录 `D:\Users\<账户>\.workbuddy` 与 `WorkBuddy` 已被创建；
  2. 提权执行 `.\wb-apply-users-v1.0.0.ps1 -Verify` 可打印各账户 4 个变量的实际值；
  3. 对方启动 WorkBuddy 后，`D:\Users\<账户>\.workbuddy\logs\` 出现新日志，
     说明程序确实在新目录工作。

## 八、版本记录

### 版本号规则

采用 `vMAJOR.MINOR.PATCH`：

- **MAJOR**：不兼容的改动（参数改名、行为变更、目录布局变化）
- **MINOR**：向后兼容的新功能（新增参数、新增模式）
- **PATCH**：向后兼容的修复（缺陷修正、提示文案）

### 变更历史

| 版本 | 日期 | 变更内容 |
|---|---|---|
| **v1.0.0** | 2026-10-31 | 首个正式版本。包含两个主脚本与三个启动器：<br>· `wb-switch-user`：当前账户的数据目录 + 工作区迁移，支持进度显示、跳过可再生目录、环境变量写入与 `WM_SETTINGCHANGE` 广播；<br>· `wb-apply-users`：以管理员身份批量处理其他账户，通过加载 `NTUSER.DAT` 写入各自配置，含 `-Verify` 只读校验与 `-Rollback` 撤销；<br>· 目录 ACL 授权、`defaultWorkspacePath` 改写、迁移前结束进程等能力。<br>· 文件名引入版本号，脚本内置 `$ScriptVersion` 并在启动时打印；<br>· 项目命名「WorkBuddy 搬家器」，启动横幅统一显示「项目名 + v版本 + 脚本名」；<br>· 配套 MIT 许可证、版本徽章与仓库 topics。 |

### 升级版本的同步清单

改版本号时，以下四处必须一起改，缺一处就会不一致：

1. **文件名**：`wb-*.ps1` 与对应 `.bat` 全部改成新版本号；
2. **启动器内引用**：`.bat` 里的 `set "SCRIPT=%~dp0...ps1"` 与提示文案中的文件名；
3. **脚本内常量**：两个 `.ps1` 的 `$ScriptVersion` 及头部注释「版本：」行；
4. **本文档**：顶部「当前版本」、文件结构表、命令示例，以及上面的变更历史表。

> `.ps1` 含中文，保存时必须是 **UTF-8 带 BOM**（Windows PowerShell 5.1 依赖 BOM 识别编码）；
> `.bat` 必须**纯 ASCII 且无 BOM**，否则 cmd 按 GBK 解析会出现「不是内部或外部命令」。
> 因此 `.bat` 的横幅使用英文名 `WorkBuddy Migrator`，中文项目名只出现在 `.ps1` 与本文档中。

## 九、许可证

本项目采用 [MIT 许可证](LICENSE)，版权归 © 2026 voipfox2 所有。
可自由使用、修改与再分发，仅需保留版权与许可声明。

## 十、CI 自动发布

仓库内置 [`.github/workflows/release.yml`](.github/workflows/release.yml)：推送 `v*` 标签时，
GitHub Actions 会自动把仓库（排除 `.git` 与 `.workbuddy`）打包成 zip，并创建 / 更新同名 Release
（含自动生成的发布说明）。无需再手动上传资产。

后续发版只需两步：

```bash
git tag -a v1.0.1 -m "WorkBuddy 搬家器 v1.0.1"
git push origin v1.0.1
```

> 注意：`permissions: contents: write` 已为该工作流授予发布权限；本地推 tag 用的仍是你自己的账号，
> 与 CI 无关。

## 十一、其他项目上传提示词

[`GITHUB_UPLOAD_PROMPT.md`](GITHUB_UPLOAD_PROMPT.md) 沉淀了本项目上传 GitHub 的完整经验，
内含一份**可直接复制给 AI 的通用提示词模板**，以及本机实测踩过的 7 类坑（代理 TLS、提交乱码、
Release 字段缺失、资产 422、描述问号、换行符/BOM 保护、PAT 不落盘）。其它项目需要上传 GitHub 时复用即可。

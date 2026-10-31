# 上传项目到 GitHub 的提示词（可复用模板）

本文件是一份「交给 AI 助手」的提示词模板，沉淀自 `workbuddy-mover` 项目的实际上传过程。
其它项目需要上传 GitHub 时，复制下面的 **通用提示词** 给 AI，并按 **经验清单** 核对即可。

---

## 一、通用提示词（直接复制给 AI）

```
把当前工作区项目上传到 GitHub。
基本信息：仓库名 <仓库名>，可见性 <公开/私有>，GitHub 账号 <用户名> <邮箱>，初始版本 <vX.Y.Z>。

请按以下流程执行，并逐项向我汇报结果：

1. 本地初始化
   - git init -b main；配置 user.name / user.email 为我的账号。
   - 添加 .gitignore（排除本地缓存、密钥、.workbuddy、编辑器杂项）。
   - 添加 .gitattributes，写入 `* -text` 关闭换行符转换——这能保护 Windows 脚本的 CRLF 与 UTF-8 BOM，避免 cmd 解析失败或中文乱码。
   - 首次提交。

2. 创建远程仓库并推送
   - 通过 GitHub API（PAT，权限 repo）以我的账号创建仓库；令牌只走请求头（Authorization: token），严禁写入 .git/config、严禁拼进 URL。
   - 推送 main 分支；推送后执行 git diff（或比对 blob/rev-parse）确认远端与本地字节一致，BOM/CRLF 不丢；最后把 origin 还原为干净 HTTPS 地址，并校验 .git/config 无任何令牌残留。

3. 版本与元信息
   - 打标签 v<版本> 并推送。
   - 加 LICENSE（通用脚本类选 MIT）。
   - 设 topics（如 powershell、windows、workbuddy、migration 等）。
   - README 顶部加版本徽章与许可证徽章。

4. 发布 Release
   - 创建 GitHub Release（基于该 tag），附打包好的 zip 资产；说明写清用途与使用要点。

5. 收尾
   - 完成后明确提醒我去 GitHub 撤销本次使用的 PAT。

环境注意（本机实测）：
- 网络走代理且会抖动，必要时用 `git -c http.proxy=` 或 `http.sslVerify=false` 绕过直连。
- PowerShell 发送含中文的 JSON 必须转成 UTF-8 字节体（[Text.Encoding]::UTF8.GetBytes + ContentType 'application/json; charset=utf-8'），否则描述/名称会变成问号。
- 创建 Release 的请求体必须包含 tag_name、name、target_commitish 等完整字段，只传 body 会返回 400。
- 资产上传端点用 uploads.github.com（不是 api.github.com），同名资产重复上传返回 422。
- 提交信息若含中文，用 UTF-8 文件 + `git commit -F` 传入，避免 PowerShell 按 GBK 传给 git 产生乱码。
```

---

## 二、上传前核对清单

| 项 | 要点 |
|---|---|
| 凭据 | 只用 PAT（权限 `repo`），用完即撤销；不要硬编码进任何文件 |
| 换行符 | `.bat`/脚本保持 CRLF；`.gitattributes` 加 `* -text` 防止被规范化 |
| 编码 | `.ps1` 等含中文文件需 UTF-8 **带 BOM**（Windows PowerShell 5.1 依赖 BOM 识别）；`.bat` 必须纯 ASCII 无 BOM |
| 排除项 | 本地缓存、密钥、`.workbuddy/`、`.git/` 不得入库 |
| 一致性 | 推送后 `git diff` 远端/本地为空、rev-parse SHA 相同 |
| 清理 | 推送后 `.git/config` 无 `ghp_`、无 `extraheader`/`AUTHORIZATION` |

---

## 三、本机实测踩过的坑（经验沉淀）

1. **GitHub App 连接器只有读权限**，`POST /user/repos` 建仓库返回 403。批量上传请用 PAT。
2. **代理 TLS 握手失败**：schannel 校验吊销列表报 `CRYPT_E_NO_REVOCATION_CHECK`；`http.schannelCheckRevoke=false` 无效、`sslBackend=openssl` 报无本地颁发者；最终 `http.sslVerify=false` + 绕过代理直连可用。
3. **提交信息乱码**：PowerShell 把中文按 GBK 传给 git → `git commit -m` 出现乱码。改用 `git commit -F <utf8文件>`。
4. **Release 创建 400**：请求体只传了 `body`，缺 `tag_name`/`name` 等必填字段。
5. **资产上传 422**：同名资产已存在时重复上传被拒；PowerShell 非交互模式下 `Invoke-WebRequest` 上传完会报「非交互模式」无害警告，以远端 `size` 校验为准。
6. **仓库描述变问号**：`Invoke-RestMethod` 不带 charset 时不按 UTF-8 发 JSON。统一用 UTF-8 字节体。
7. **CI 自动发版**：见 `.github/workflows/release.yml`，打 `v*` tag 自动打包并 upsert Release（含 `permissions: contents: write`）。
8. **推送 workflow 需 `workflow` scope**：含 `.github/workflows/` 变更的提交，GitHub 会拒绝仅有 `repo` 权限的 PAT，必须重新生成（或在原 token 勾选）`workflow` 作用域。若暂时不想加该 scope，可先把 workflow 文件排除出本次提交，其余文档照常推送，CI 留待后续补推。

---

## 四、CI 自动发布（可选）

仓库已内置 `.github/workflows/release.yml`：推送 `v*` 标签即自动打包仓库（排除 `.git`、`.workbuddy`）并发布 Release，免去手动上传。
后续发版只需：

```
git tag -a vX.Y.Z -m "说明"
git push origin vX.Y.Z
```

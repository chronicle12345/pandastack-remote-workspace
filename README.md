# PandaStack 远程浏览器一键部署包

`deploy.ps1` 在 PandaStack 上创建或更新远程桌面浏览器，写入运行所需的 secret，触发部署，并检查登录、会话、终端、浏览器和窗口按钮。

远程桌面终端、Chromium 和 SSH 使用 root 账户。系统不创建 dev 用户，也不配置 sudo。

## 免责声明

本项目仅供学习、研究和技术交流使用，不构成生产环境部署建议、服务承诺或安全保证。使用者应自行评估部署环境、账号权限、网络配置和第三方平台条款，并承担使用本项目产生的全部风险与责任。作者不对因使用或无法使用本项目造成的任何直接或间接损失、数据丢失、服务中断、账号封禁、安全问题或法律责任承担责任。请遵守所在地法律法规以及 PandaStack、Cloudflare 等第三方平台的服务条款。

## 前置条件

- Windows 10 或 Windows 11，Windows PowerShell 5.1 或 PowerShell 7。
- Python 3.10 或更高版本，`python` 已加入 `PATH`。
- Windows OpenSSH Client，默认路径为 `C:\Windows\System32\OpenSSH\ssh.exe`。
- PandaStack 账号和 API Key。
- 免费套餐有 CPU、内存和运行时长限制，App 闲置后会休眠。

Linux 和 macOS 可以使用标准 SSH 客户端手动配置 `ProxyCommand`，本目录没有提供对应脚本。

### SSH 密钥

SSH 使用 root 公钥登录。默认路径是部署包目录下的 `.\pandastack-root.pub`。首次部署时，如果公钥和私钥都不存在，`deploy.ps1` 会自动生成一对 ed25519 密钥：

```text
SSH_PUBLIC_KEY_PATH=.\pandastack-root.pub
```

相对路径以部署包目录为基准，不受 PowerShell 当前工作目录影响。私钥是同目录下的 `pandastack-root`，`.gitignore` 已排除这两个文件。填写 `off` 可以禁用 SSH。

更换密钥时，删除 `pandastack-root` 和 `pandastack-root.pub`，再运行 `deploy.ps1` 生成新密钥并写入远端 `/root/.ssh/authorized_keys`。

### .env 配置项

| 名称 | 必填 | 说明 |
| --- | --- | --- |
| `PDS_API_KEY` | 部署时 | PandaStack API Key。留空时脚本会提示输入 |
| `PDS_APP_ID` | 更新和 SSH 时 | 已有 App 的 ID。新建 App 时留空 |
| `PDS_PUBLIC_URL` | 否 | App 的公网地址（含 `https://`），部署后自动写回 |
| `PDS_APP_NAME` | 否 | App 名称，默认 `pandastack-browser` |
| `PDS_GIT_URL` | 否 | PandaStack 的仓库地址，默认使用 noVNC 仓库 |
| `PDS_GIT_BRANCH` | 否 | 仓库分支，默认 `master` |
| `PDS_TEMPLATE` | 否 | App 模板，默认 `browser` |
| `PDS_PORT` | 否 | App 端口，默认 `6080` |
| `PDS_IDLE_TIMEOUT_SECONDS` | 否 | 闲置休眠时间，默认 `1800` 秒 |
| `PDS_AUTO_HIBERNATE` | 否 | 是否自动休眠，默认 `true` |
| `BROWSER_PASSWORD` | 否 | 网页登录密码，也用于 SSH 桥接的网页会话认证；留空时自动生成 32 位随机密码 |
| `ROOT_PASSWORD` | 否 | root 账户密码，用于本地控制台和 `su -` |
| `SESSION_TTL_MINUTES` | 否 | 网页会话有效期，默认 180 分钟，范围 1 到 10080 |
| `SSH_PUBLIC_KEY_PATH` | 否 | 本地 SSH 公钥路径，默认 `.\pandastack-root.pub`，首次部署自动生成密钥；填 `off` 禁用 SSH |
| `WORKSPACE_DATABASE_URL` | 否 | 工作区快照数据库连接串 |
| `WORKSPACE_KEY` | 否 | 工作区快照加密密钥 |
| `WORKSPACE_ID` | 否 | 工作区快照标识，默认 `pandastack-workspace` |

## 环境检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-requirements.ps1
```

脚本会检查依赖、配置、可选的 SSH 密钥和 websocket-client wheel 的哈希。

## 部署

1. 复制 `.env.example` 为 `.env`。
2. 填写 `PDS_API_KEY` 和 App 配置；需要 SSH 时再填公钥路径。
3. 检查配置：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1 -DryRun
   ```

4. 执行部署：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1
   ```

## 网页登录

打开部署输出中的登录地址，格式为：

```text
https://<公网域名>/login
```

用户名是 `browser`，密码是 `.env` 中的 `BROWSER_PASSWORD`。

## SSH 连接

PandaStack App 只对外开放 HTTPS 端口，容器内的 sshd 监听 `127.0.0.1:22`。`connect-ssh.ps1` 先登录网页取得会话，再通过 `ssh_bridge.py` 建立 `wss://<公网域名>/ssh` 连接，最后由 Windows OpenSSH 完成 root 公钥认证。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\connect-ssh.ps1
```

使用本地 HTTP 代理：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\connect-ssh.ps1 -Proxy http://127.0.0.1:7890
```

网页会话有效期由 `SESSION_TTL_MINUTES` 控制，默认 180 分钟，范围 1 到 10080 分钟。会话过期后重新运行连接脚本。

每次部署会生成新的 SSH 主机密钥，连接脚本关闭了 known_hosts 校验。需要严格校验时，先固定远端主机密钥，再修改连接脚本。

## 部署结果

部署成功后，脚本输出 App ID、App 名称、公网地址、登录地址、部署状态、会话有效期、密码保存位置和报告路径。公网地址会写回 `.env` 的 `PDS_PUBLIC_URL`。

## 更新与验证

把已有 App ID 填入 `.env` 的 `PDS_APP_ID`，再运行部署脚本。也可以临时指定 App ID：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1 -AppId <APP_ID>
```

检查现有 App 的登录和三个桌面按钮，不重新部署：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1 -VerifyOnly
```

## 文件说明

- `deploy.ps1`：一键部署脚本
- `connect-ssh.ps1`：登录网页并建立 root SSH 连接
- `check-requirements.ps1`：检查本地环境、配置和密钥
- `ssh_bridge.py`：通过网页 WebSocket 转发 SSH 的本地桥接脚本
- `src/`：部署到 PandaStack 的源码
- `docs/DEPLOYMENT.md`：部署过程记录
- `THIRD_PARTY_NOTICES.md`：第三方文件来源、版本、许可证和 SHA-256

## 安全

- `.env` 保存真实密钥，并已加入 `.gitignore`。
- PandaStack API Key 通过请求头发送。
- 网页密码、root 密码、数据库连接串和工作区密钥以 secret 形式写入 PandaStack。
- SSH 部署读取公钥，私钥留在本地。
- 工作区快照是可选功能，同时配置数据库连接串和工作区密钥后启用。未配置的可选 secret 会从 PandaStack 删除。快照排除 `.env`、SSH 密钥、证书和常见凭据文件。

## 验证

```powershell
python -m unittest discover -s tests -v
```

如果安装了 Node.js，可以额外运行 `node --check src\desktop.js`。

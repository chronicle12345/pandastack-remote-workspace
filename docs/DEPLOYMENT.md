# 部署过程记录

## 1. 设计目标

在 PandaStack 上运行一个可长期使用的远程桌面浏览器。App 定义和网址保留，运行沙箱可以休眠和重建。网页入口使用独立密码、会话保护、登录失败限流和桌面快捷操作。

远程桌面和 SSH 使用 root 账户。

## 2. 本地环境

环境要求和 `.env` 配置见 `README.md`。部署前运行 `check-requirements.ps1`。

## 3. PandaStack 配置

- `git_url` 使用公开的 noVNC 仓库。
- `template` 使用 `browser`，提供 Chromium、Playwright 和 Xvfb。
- `build_command` 覆盖默认构建流程，把 `src/` 写入远端 `/app`，再执行 `build.sh`。
- `start_command` 执行 `bash /app/start-browser.sh`，启动桌面、VNC、SSH 和网关。
- App 端口为 `6080`，由 PandaStack 转发到公网 HTTPS 域名。
- 环境变量通过 PandaStack 的 secret 接口写入。

## 4. 构建阶段

`build.sh` 完成以下工作：

1. 安装 Xvfb、x11vnc、noVNC、websockify、Openbox、xterm、中文字体、OpenSSH 和 Python 依赖。
2. 删除旧的 dev 用户和 sudoers 配置。
3. 从 browser 模板的 Playwright 缓存中复制 Chromium。
4. 安装桌面操作程序和浏览器启动器，浏览器资料目录使用 `/root/browser-profile`。
5. 替换 noVNC 的入口页面和 Openbox 菜单。
6. 生成 SSH 主机密钥。

## 5. 启动阶段

`start-browser.sh` 完成以下工作：

1. 读取 `BROWSER_PASSWORD`，生成 x11vnc 密码文件；读取 `ROOT_PASSWORD`，设置 root 密码。
2. 配置 root 的 SSH 公钥并启动 sshd；默认使用部署包目录下的 `.\pandastack-root.pub`，首次部署缺失时自动生成。
3. 容器工作区为空时恢复 `/workspace` 的加密快照；已有文件时保留现有工作区。快照排除 `.env`、SSH 密钥、证书和常见凭据文件。
4. 以 root 身份启动 Xvfb、Openbox、Chromium 和 xterm。
5. 启动 x11vnc，监听本机 5900 端口。
6. 启动 Python 网关，监听 6080 端口。

## 6. 网关行为

- 网页登录使用独立密码。
- 登录成功后签发由 `SESSION_TTL_MINUTES` 控制的签名会话。
- 会话令牌与密码绑定，修改密码后旧会话失效。
- 登录失败达到五次后，同一来源地址在十五分钟内被限制；另有全局失败上限。
- 桌面操作使用与会话绑定的 CSRF 令牌。
- VNC WebSocket 和 SSH WebSocket 都经过同一网关认证。
- 响应包含禁止缓存、禁止搜索引擎收录、禁止摄像头和麦克风权限等安全头。

## 7. 环境变量

部署脚本从本地 `.env` 读取配置，再把需要的值写入 PandaStack secret。`SSH_PUBLIC_KEY_PATH` 默认是 `.\pandastack-root.pub`，填 `off` 可禁用 SSH；它和 `WORKSPACE_DATABASE_URL` 是本地配置名，写入远端时分别转换为 `SSH_AUTHORIZED_KEY_B64` 和 `DATABASE_URL_B64`。

| 名称 | 必填 | 说明 |
| --- | --- | --- |
| `BROWSER_PASSWORD` | 否 | 网页登录和 VNC 密码，留空时脚本自动生成 |
| `ROOT_PASSWORD` | 否 | root 账户密码，脚本可自动生成；用于本地控制台和 `su -` |
| `SESSION_TTL_MINUTES` | 否 | 网页会话有效期，单位分钟，默认 180，范围 1 到 10080 |
| `SSH_AUTHORIZED_KEY_B64` | 否 | root 的 SSH 公钥 Base64；未配置时删除 |
| `DATABASE_URL_B64` | 否 | 工作区快照数据库连接串的 Base64 |
| `WORKSPACE_KEY` | 否 | 工作区快照的 Fernet 密钥 |
| `WORKSPACE_ID` | 否 | 工作区快照标识 |

## 8. 部署流程

1. 读取本地 `.env`。
2. 生成随机网页密码和 root 密码，或使用已配置的密码。
3. 检查 SSH 密钥；默认路径缺失时生成 ed25519 密钥对。
4. 生成构建命令，把 `src/` 文件编码后写入远端 `/app`。
4. 创建 App 或更新已有 App。
5. 写入加密环境变量，包括网页密码、root 密码和 `SESSION_TTL_MINUTES`，并删除未配置的可选 secret。
6. 触发部署并轮询状态，直到 `live` 或失败。
7. 登录网页，检查会话接口返回 CSRF 令牌。
8. 依次调用终端、浏览器和窗口操作，确认返回 `ok: true`。

## 9. 常见问题

### 部署状态为 failed

查看脚本输出的构建日志末尾。常见原因是端口没有监听在 `0.0.0.0`，或者环境变量缺失。部署脚本会在上传前把文本文件统一转换为 LF。

### 网页按钮返回 403

页面会在 CSRF 失效后自动重新获取令牌并重试一次。仍失败时检查 `/session` 是否返回 `csrf`，按钮请求必须携带 `X-CSRF-Token`。

### App 休眠后连接断开

PandaStack 免费套餐会按闲置时间休眠。重新打开网页会唤醒 App。已建立的 WebSocket 连接会延长运行时间，套餐额度仍然适用。

### 如何更新代码

修改 `src/` 后重新运行 `deploy.ps1`。脚本会更新构建命令并触发部署。

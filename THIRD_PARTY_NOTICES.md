# 第三方文件来源

本部署包中的 `websocket_client-1.9.2-py3-none-any.whl` 来自 Python 包索引 PyPI 的官方发布，用于本地 `ssh_bridge.py` 建立 `wss://<公网域名>/ssh` 连接。

| 项目 | 内容 |
| --- | --- |
| 文件 | `websocket_client-1.9.2-py3-none-any.whl` |
| 包名 | `websocket-client` |
| 版本 | `1.9.2` |
| 官方项目页 | [PyPI 项目页](https://pypi.org/project/websocket-client/1.9.2/) |
| PyPI JSON 元数据 | [PyPI JSON](https://pypi.org/pypi/websocket-client/1.9.2/json) |
| 官方下载地址 | [PyPI wheel](https://files.pythonhosted.org/packages/d5/d2/cc4dc1271e464942db7ee278baae2daa99ee77cb2af744025c04da585a3e/websocket_client-1.9.2-py3-none-any.whl) |
| 上游源码 | [GitHub 仓库](https://github.com/websocket-client/websocket-client) |
| 文件大小 | 95,786 字节 |
| SHA-256 | `e1a673830a9c7bfa47b1cd3d5e4178f4c9651d80a4eab02c9c23a1c3ec6250ce` |
| 许可证 | Apache-2.0 |
| Python 要求 | 3.10 或更高 |

核对日期：2026-10-23。官方 wheel 的文件名、大小和 SHA-256 与本地文件一致。wheel 内包含 `websocket_client-1.9.2.dist-info/METADATA`、`WHEEL`、`RECORD` 和 Apache-2.0 许可证文件。

## 校验方法

在部署包目录运行：

```powershell
Get-FileHash .\websocket_client-1.9.2-py3-none-any.whl -Algorithm SHA256
```

预期结果：

```text
e1a673830a9c7bfa47b1cd3d5e4178f4c9651d80a4eab02c9c23a1c3ec6250ce
```

验证 Python 能从这个 wheel 导入包：

```powershell
python -c "import sys; sys.path.insert(0, r'.\websocket_client-1.9.2-py3-none-any.whl'); import websocket; print(websocket.__version__)"
```

预期输出：

```text
1.9.2
```

## 其他文件

部署包没有其他第三方二进制文件。`src/__pycache__/` 和 `tests/__pycache__/` 是测试缓存，已由 `.gitignore` 排除。`.env` 是本地配置文件，包含真实密钥。

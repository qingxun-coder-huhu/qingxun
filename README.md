# 清巡（Qingxun）

**网络设备 CLI 自动化平台 · 开源版**

清巡把「用自然语言描述需求 → AI 生成脚本 → 在模拟设备上自测评估 → 在真实设备上执行 → 查看报告」整条链路收在一个自托管的 Web 应用里。它不需要注册账号，大模型 Key 由使用者在配置文件中自备。

> 本仓库是**开源版（社区版）**：单一 Rails 应用，免登录、单租户、配置驱动。
> 一个功能更全的托管版本（含账号体系、识别码、管理后台、在线分发等）独立维护，二者通过
> [docs/OSS_SYNC_MAP.md](docs/OSS_SYNC_MAP.md) 记录的文件对应关系来同步功能。

## 能力

- **脚本生成**：用自然语言描述要做什么（可附手工操作日志），大模型生成 `Qingxun::DeviceScript` 脚本与命令映射。
- **自动测试与评估**：内置模拟设备（FakeTelnetServer）先空跑生成的脚本，再由大模型逐条核对是否满足需求，不通过会自动重试并给出问题清单。
- **脚本管理**：版本历史、回滚、主线/分支场景、命令映射维护。
- **设备管理**：维护设备连接信息（Telnet/SSH、账号、密码、提权），密码加密存储。
- **任务执行**：把若干脚本下发到若干设备并发执行，逐条记录状态、耗时、日志与返回值。
- **自定义集成**：在脚本中调用自定义函数（如发送告警）。

## 快速开始

### 方式一：Docker Compose（推荐）

```bash
git clone <this-repo> qingxun && cd qingxun

# 1) 基础环境变量
cp .env.example .env
#   生成运行密钥并填入 .env 的 SECRET_KEY_BASE
bin/rails secret   # 或者用 openssl rand -hex 64
#   顺便把 DATABASE_PASSWORD 设成一个自定义值

# 2) LLM 配置（Key 只在这里维护）
cp config/qingxun.yml.example config/qingxun.yml
#   编辑 config/qingxun.yml，填入 llm.api_key

# 3) 启动
docker compose up -d
#   访问 http://<你的主机>:3000
```

> 不想挂载配置文件也可以：在 `.env` 里设置 `QINGXUN_LLM_API_KEY`（以及可选的
> `QINGXUN_LLM_API_URL` / `QINGXUN_LLM_MODEL`），并在 `docker-compose.yml` 中注释掉
> `config/qingxun.yml` 那一行挂载。

### 方式二：本地运行

```bash
bundle install
cp .env.example .env      # 填 DATABASE_* 与 SECRET_KEY_BASE
cp config/qingxun.yml.example config/qingxun.yml   # 填 llm.api_key
bin/rails db:prepare
bin/rails server
```

需要 Ruby 3.2+ 与 PostgreSQL。

## 配置

| 配置项 | 位置 | 说明 |
| --- | --- | --- |
| LLM Key / 端点 / 模型 | `config/qingxun.yml`（或 `QINGXUN_LLM_*` 环境变量） | Key 只在配置中维护，不写库、不进日志 |
| 数据库、`SECRET_KEY_BASE`、`ALLOWED_HOSTS`、`SITE_ORIGIN` | `.env` | 见 `.env.example` |
| 执行并发 / 超时 / 沙箱 | `config/qingxun.yml` 的 `execution` 段 | |

设备连接密码使用从 `SECRET_KEY_BASE` 派生的密钥加密存储（可显式覆盖，见
`config/initializers/active_record_encryption.rb`）。因此**不要随意更换 `SECRET_KEY_BASE`**，
否则已保存的设备密码将无法解密。

## 目录结构

```
app/
├── controllers/          # 脚本生成、设备、任务、帮助页
├── models/               # user / script / task / network_element / task_execution ...
├── services/             # 生成、评估、自动重试、沙箱测试、真机执行（device_runner/task_runner）
└── views/
lib/qingxun/              # 脚本框架：DeviceScript 基类、Sandbox、日志等
lib/telnet_device.rb      # Telnet / SSH 设备连接
lib/fake_telnet_server.rb # 模拟设备（自测用）
config/qingxun.yml.example
docker-compose.yml
docs/OSS_SYNC_MAP.md      # 与托管版本的文件对应关系（同步用）
```

写脚本时继承 `Qingxun::DeviceScript` 并实现 `run(connection)`；细节见
[docs/requirement-writing-guide.md](docs/requirement-writing-guide.md)、
[docs/tree-command-mapping-examples.md](docs/tree-command-mapping-examples.md) 与
[client_custom_ai_guide.md](client_custom_ai_guide.md)。

## 安全提示

- 设备日志与脚本可能包含敏感回显；`logs/`、`tmp/` 已在 `.gitignore` 中，部署时请持久化并妥善保护。
- 生成的脚本请先在测试环境验证，再用于生产设备。

## 许可证

本项目以 **AGPL-3.0** 发布，见 [LICENSE](LICENSE)。

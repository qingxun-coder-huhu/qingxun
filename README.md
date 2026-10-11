# 清巡（Qingxun）

**网络设备 CLI 自动化平台 · 开源版**

[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/ruby-3.2-red.svg)](.ruby-version)
[![Rails](https://img.shields.io/badge/rails-7.1-red.svg)](Gemfile)
[![PostgreSQL](https://img.shields.io/badge/postgresql-16-blue.svg)](https://www.postgresql.org/)

清巡把「用自然语言描述需求 → AI 生成脚本 → 在模拟设备上自测评估 → 在真实设备上执行 → 查看报告」
整条链路收在一个自托管的 Web 应用里。**不需要注册账号**，大模型 Key 由使用者在配置文件中自备，
设备与脚本数据全部留在你自己的部署里。

> 本仓库是**开源版（社区版）**：单一 Rails 应用，免登录、单租户、配置驱动，可自托管、可自由修改。
>
> 🌐 **在线体验版**：<https://qingxun.online> —— 不想自己部署，可直接在线上试用。

---

## 特性

- **脚本生成**：用自然语言描述要做什么（可附手工操作日志），大模型生成 `Qingxun::DeviceScript` 脚本与命令映射。
- **自动测试与评估**：内置模拟设备（`FakeTelnetServer`）先空跑生成的脚本，再由大模型逐条核对是否满足需求；不通过会自动重试并给出问题清单。
- **脚本管理**：版本历史、回滚、主线/分支场景、命令映射维护、按设备型号匹配。
- **设备管理**：维护设备连接信息（Telnet/SSH、账号、密码、提权），密码加密存储。
- **任务执行**：把若干脚本下发到若干设备并发执行，逐条记录状态、耗时、日志与返回值。
- **报告**：按设备/脚本汇总执行结论，网页查看与导出。
- **自定义集成**：在脚本中调用自定义函数（如发送告警）。

## 工作流程

```
① 登记设备与型号  →  ② 生成脚本并自测通过（标记「调试完成」）  →  ③ 生成/编辑任务  →  ④ 下发执行  →  ⑤ 查看日志与报告
```

- 应用内置「使用指南」「如何编写描述」「帮助」三个页面，从顶部导航即可进入；写描述与命令映射的要点也见下方[写脚本](#写脚本)一节。

## 快速开始

```bash
git clone <this-repo> qingxun && cd qingxun

bundle install
cp .env.example .env                               # 填 DATABASE_* 与 SECRET_KEY_BASE
cp config/qingxun.yml.example config/qingxun.yml   # 填 llm.api_key
bin/rails db:prepare
bin/rails server
```

需要 **Ruby 3.2+** 与 **PostgreSQL**。`SECRET_KEY_BASE` 可用 `bin/rails secret` 生成。

## 配置

| 配置项 | 位置 | 说明 |
| --- | --- | --- |
| LLM Key / 端点 / 模型 | `config/qingxun.yml`（或 `QINGXUN_LLM_*` 环境变量） | Key 只在配置中维护，不写库、不进日志；改动后无需重启 |
| 数据库、`SECRET_KEY_BASE`、`ALLOWED_HOSTS`、`SITE_ORIGIN` | `.env` | 见 `.env.example` |
| 执行并发 / 超时 / 沙箱 | `config/qingxun.yml` 的 `execution` 段 | 控制同时下发的设备数等 |

设备连接密码使用从 `SECRET_KEY_BASE` 派生的密钥加密存储（可显式覆盖，见
`config/initializers/active_record_encryption.rb`）。因此**不要随意更换 `SECRET_KEY_BASE`**，
否则已保存的设备密码将无法解密。

## 技术架构

- **后端**：Ruby on Rails 7.1 / Ruby 3.2 / PostgreSQL，单一应用，无外部服务依赖。
- **前端**：Vue 3 + Element Plus（本地 vendored，无 CDN、无构建步骤）。
- **真机执行**：复用桌面客户端的任务编排层（线程池并发、登录/提权、日志缓冲），脚本统一在 `Qingxun::Sandbox` 中运行。
- **大模型**：兼容 OpenAI 风格的接口，端点与模型可在配置文件中指定。

### 目录结构

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
```

## 写脚本

脚本继承 `Qingxun::DeviceScript` 并实现 `run(connection)`；生成脚本由大模型完成，手写或微调时细节见：

- [docs/requirement-writing-guide.md](docs/requirement-writing-guide.md) —— 怎么写需求描述
- [docs/tree-command-mapping-examples.md](docs/tree-command-mapping-examples.md) —— 命令映射示例
- [client_custom_ai_guide.md](client_custom_ai_guide.md) —— 自定义集成

## 安全提示

- 设备日志与脚本回显可能包含敏感信息；`logs/`、`tmp/` 已在 `.gitignore` 中，部署时请持久化并妥善保护。
- 生成的脚本请先在测试环境验证，再用于生产设备。
- 大模型调用使用你自己配置的 API Key，费用由你的大模型服务商收取，本项目不代收任何费用。

## 许可证

本项目以 **AGPL-3.0** 发布，见 [LICENSE](LICENSE)。

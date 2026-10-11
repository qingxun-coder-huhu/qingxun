# AGENTS_zh.md

面向 AI 代理（与开发者）的**清巡开源版（社区版）**工作指南。

> 这是独立发布的单租户版本：免登录、无账号体系、LLM Key 放在配置文件里，
> 脚本生成与真机执行都在同一个 Rails 应用中完成。托管版独立维护，两者的
> 文件对应关系见 [docs/OSS_SYNC_MAP.md](docs/OSS_SYNC_MAP.md)——
> **在引入或移植任何功能前，先读那份说明**。

## 技术栈

- Ruby 3.2 / Rails 7.1 / PostgreSQL / Puma
- 测试用 RSpec；未配置代码风格检查器
- 前端：服务端渲染 ERB + Bootstrap 5（静态资源是 `public/` 下的普通文件）

## 常用命令

```bash
bundle install
bin/rails db:prepare           # 建库 + 迁移
bin/rails server               # http://localhost:3000
bundle exec rspec              # 全量测试
bundle exec rspec spec/services/device_runner_spec.rb:12   # 单条用例
bin/rails zeitwerk:check       # 预加载自检
```

测试需要 PostgreSQL，本地走 unix socket：

```bash
DATABASE_HOST=/var/run/postgresql DATABASE_USERNAME=<用户> RAILS_ENV=test bundle exec rspec
```

## 关键入口

- **脚本生成 / 评估闭环**：`app/services/auto_generate_service.rb`、
  `script_generation_service.rb`、`script_evaluation_service.rb`、`debug_session.rb`
  （把生成的代码放到 `FakeTelnetServer` 上试跑），提示词在 `app/services/prompts/`。
- **大模型访问**：`app/services/llm_request_service.rb` + `llm_api_key.rb` +
  `qingxun_config.rb`（读 `config/qingxun.yml`）。
- **真机执行**：`app/services/task_runner.rb`（按「设备 × 脚本」扇出）、
  `app/services/device_runner.rb`（连接设备并在 `Qingxun::Sandbox` 里跑单个脚本）。
- **脚本框架**：`lib/qingxun/`（`DeviceScript` 基类、`Sandbox`、日志）。
- **设备连接**：`lib/telnet_device.rb`（Telnet/SSH）。

## 约定

- 脚本继承 `Qingxun::DeviceScript`，实现 `run(connection)`。
- 密码 / LLM Key 绝不入明文库或日志。设备凭据用 ActiveRecord::Encryption 加密，
  密钥由 `SECRET_KEY_BASE` 派生。
- `config/qingxun.yml` 是 LLM Key 的唯一归口；`.env` 放部署级密钥。
- 注释保持中文，与现有代码风格一致。
- 从上游同步时，遵守 `docs/OSS_SYNC_MAP.md` 记录的行为约定。

## 不要重新引入（线上专属）

账号/登录/激活、客户识别码与 JWT、`/admin` 后台、邮件、API 用量遥测、
请求级 BYOK Key、SEO/文章页，以及独立的本地客户端应用。详见
`docs/OSS_SYNC_MAP.md` 的「已删除」清单。

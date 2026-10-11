# 开源版 ↔ 线上版 文件关系与同步说明

本文件是**开源版（本仓库）与线上托管版之间的同步契约**。线上版由两个私有仓库组成：

- `net_cat` —— 云端 Rails 应用（含脚本生成、账号体系、管理后台、分发等）
- `net_cat_client` —— 本地 Sinatra 执行客户端（真机执行、报告）

开源版本仓库把这两者**合并为单一 Rails 应用**并做了社区化裁剪。两个版本从此独立演进，
**没有 git 合并关系**；功能同步靠本文件记录的对应关系人工 / AI 完成。

## 怎样用本文件同步功能

1. 在线上版找到目标改动，确认它落在下面「核心文件」表里的哪一项。
2. 在开源版打开对应路径，比对并移植；**只移植与核心能力相关**的逻辑。
3. 若改动碰到了「已删除（线上专属）」清单里的东西，不要带回——那是有意剥离的。
4. 移植后遵守下面「行为差异」一节里的既定差异，不要"改回"线上行为。

---

## 目录级对应关系

| 开源版路径 | 上游来源 | 状态 | 同步注意 |
| --- | --- | --- | --- |
| `app/services/{auto_generate,script_generation,script_evaluation,debug_session,branch_*,script_version_*,command_mapping_parser,fake_telnet_server_manager,description_draft_payload,script_requirement_draft_service,script_description_improvement_service,integration_code_builder,markdown_renderer}.rb` | `net_cat/app/services/` 同名 | **原样复制** | 可直接 diff 上游同名文件移植 |
| `app/services/prompts*` | `net_cat/app/services/prompts*` | **原样复制** | 同上；提示词改动通常可直接带过来 |
| `lib/qingxun/**` | `net_cat/lib/qingxun/**` | **原样复制** | 脚本框架（DeviceScript/Sandbox/日志），上游改这里要同步 |
| `lib/qingxun.rb`、`lib/qingxun_script.rb` | `net_cat/lib/` 同名 | 原样复制 | |
| `lib/telnet_device.rb`、`lib/fake_telnet_server.rb` | `net_cat/lib/` 同名 | 原样复制 | 真机连接与模拟设备；上游的客户端接口（`ip_address`/`decrypt_password`）已在本仓库设备模型上对齐 |
| `lib/external_wait.rb` | `net_cat/lib/` | 原样复制 | 等待 LLM 时归还数据库连接 |
| `app/models/{script,script_version,command_mapping,device_model,task,task_script,task_network_element,custom_integration}.rb` | `net_cat/app/models/` 同名 | **基本一致**（见差异） | 上游改了业务逻辑需同步；`task.rb` 状态机被放宽 |
| `app/models/user.rb` | `net_cat/app/models/user.rb` | **大幅精简** | 上游的识别码/微信/注销/条款全部去掉，仅留最小字段与关联 |
| `app/models/network_element.rb` | `net_cat/app/models/network_element.rb` | **改造** | 新增连接凭据字段与加密 |
| `app/controllers/scripts_controller.rb` | `net_cat/app/controllers/scripts_controller.rb` | **改造** | 主体逻辑一致；去掉了 onboarding/日志转交/配额 |
| `app/views/scripts/index.html.erb` | `net_cat/app/views/scripts/index.html.erb` | **改造** | 生成 UI 主体一致；删掉 onboarding 卡片、凭据、客户端日志转交 |
| `config/initializers/{rack_attack,assets,content_security_policy,permissions_policy,filter_parameter_logging,inflections}.rb` | `net_cat/config/initializers/` | 原样复制 | |
| `db/migrate/**`（除计费与下列新增） | `net_cat/db/migrate/**` | 原样复制 | 上游新迁移可按需带过来 |
| `docs/requirement-writing-guide.md`、`docs/tree-command-mapping-examples.md` | `net_cat/docs/` 同名 | 原样复制 | 用户文档 |
| `examples/**` | `net_cat/examples/` | 原样复制 | |
| **以下为开源版新增，无上游对应** | | | |
| `app/services/qingxun_config.rb` | — | 新增 | 读 `config/qingxun.yml` + `QINGXUN_LLM_*` |
| `app/services/device_runner.rb` | 参考 `net_cat_client` 的 `script_executor.rb` | **移植改造** | 单设备单脚本执行，走 `Qingxun::Sandbox` |
| `app/services/task_runner.rb` | 参考 `net_cat_client` 的 `task_execution_coordinator.rb` / `device_execution_processor.rb` | **移植改造** | 设备×脚本并发执行 |
| `app/models/task_execution.rb` | 参考 `net_cat_client` 的 `local_task_execution.rb` | **移植改造** | 执行结果表 |
| `app/controllers/network_elements_controller.rb`、`app/views/network_elements/**` | — | 新增 | 设备 CRUD + 测试连接 |
| `app/controllers/tasks_controller.rb`、`app/views/tasks/**` | `net_cat` 的同名控制器/视图 | **重写** | 上游是"云端编排 + 客户端执行"的文件系统版，这里重写为单应用执行 |
| `config/qingxun.yml.example`、`.env.example`、`docker-compose.yml`、`Dockerfile`、`bin/docker-entrypoint` | `net_cat` 的部署文件 | **重写** | 去掉私服镜像与生产密钥 |
| `config/initializers/active_record_encryption.rb` | — | 新增 | 设备密码加密密钥派生 |
| `docs/OSS_SYNC_MAP.md`、`README.md`、`AGENTS*.md` | — | 新增/重写 | 本文件即同步契约 |

---

## 核心文件（与上游**特意保持一致**，同步时优先 diff 这些）

这些文件是脚本生成能力的本体，改动通常可以近乎直接地从 `net_cat` 带过来：

```
app/services/auto_generate_service.rb
app/services/script_generation_service.rb
app/services/script_evaluation_service.rb
app/services/debug_session.rb
app/services/command_mapping_parser.rb
app/services/fake_telnet_server_manager.rb
app/services/branch_suggestion_service.rb
app/services/branch_consistency_service.rb
app/services/branch_mapping_generation_service.rb
app/services/script_version_recorder.rb
app/services/script_version_diff.rb
app/services/prompts.rb
app/services/prompts/**
lib/qingxun/**
lib/fake_telnet_server.rb
lib/telnet_device.rb
```

---

## 已删除（线上专属，**不要重新引入**）

| 类别 | 上游位置 | 说明 |
| --- | --- | --- |
| 账号 / 登录 / 激活 / 注册 / 找回密码 | `net_cat/app/controllers/{sessions,registrations,password_resets}_controller.rb`、视图 | 开源版免登录 |
| 免注册领码（onboarding） | `net_cat/app/controllers/onboarding_controller.rb` | 识别码体系整体不存在 |
| 客户识别码 / JWT / 对外 API | `net_cat/app/controllers/api/**`、`app/services/jwt_service.rb` | 客户端协议已不需要 |
| 管理后台 | `net_cat/app/controllers/admin/**`、`app/views/admin/**` | |
| 邮件 / Sendflare | `net_cat/app/mailers/**`、`lib/sendflare_delivery.rb` | 无账号体系，默认不发邮件 |
| API 用量遥测 / 请求日志 | `api_usage_logs` 表、`UserRequest` 模型 | 已用轻量 `GenerationRequestContext` 替代 |
| 条款 / 隐私 / 文章 / SEO / 下载页 / sitemap | `net_cat/app/controllers/articles_controller.rb`、`app/views/pages/{landing,about,privacy,terms,download}*`、`content/**`、`public/llms.txt` | |
| 本地客户端应用 | `net_cat_client/**` | 执行能力已并入本仓库 |
| 计费 / 订阅 / 信用点 | `net_cat` 的相应迁移与模型 | 上游已移除 |
| 部署密钥 / 生产配置 | `net_cat/config/deploy.yml`、`docker_cmd`、`.env.*`、`qingxun_gems/`、`release/` | 脱敏时删除 |

---

## 开源版相对上游的**行为差异**（有意为之，不要改回）

1. **免登录**：`ApplicationController` 自动以 `User.local_operator` 运行，无会话/账号。
2. **Key 来源**：LLM Key 只来自 `config/qingxun.yml`（或 `QINGXUN_LLM_*` 环境变量），
   不再有请求级 BYOK 头路径，也不再限制必须是 DeepSeek（端点在配置里可改）。
3. **生成不落遥测**：`GenerationRequestContext` 只承载 `request_id`，不写用户请求表。
4. **执行在同一应用内**：`TaskRunner` + `DeviceRunner` 直接连真机；没有云端/客户端分离，
   没有 `X-Client-Code` / JWT、没有脚本同步接口。
5. **设备凭据入库**：连接信息（IP/账号/密码）存在 `network_elements`，密码用
   ActiveRecord::Encryption 加密（密钥由 `SECRET_KEY_BASE` 派生）。
6. **任务可重复运行**：`Task#validate_status_transition` 放宽，已结束的任务可再次运行
   （上游为终态设计）。

---

## 复用自本地客户端（`net_cat_client`）的类

以下类**从客户端搬入**开源版，后续同步时应以客户端为准（尽量保持逐字一致，仅列出的适配除外）：

| 开源版路径 | 客户端来源 | 适配 |
| --- | --- | --- |
| `lib/thread_pool_executor.rb` | 同名 | 无（原样） |
| `lib/telnet_device.rb` | 同名（605 行版） | 无（整体替换了云端旧版） |
| `lib/net_ssh_telnet_flush.rb` | 同名 | 无 |
| `lib/file_path_utils.rb` | 同名 | 无 |
| `lib/device_login_handler.rb` | 同名 | 仅 require 路径 |
| `lib/script_executor.rb` | 同名 | ① 执行改走 `Qingxun::Sandbox`（保留沙箱）；② 自定义集成改由框架按 `script_user` 加载（不再 `eval`） |
| `lib/task_execution_coordinator.rb` | 同名 | 去掉 `Singleton`；线程池大小可传入 |
| `lib/device_execution_processor.rb` | 同名 | 无 |
| `lib/task_finalizer.rb` | 同名 | 无 |
| `lib/task_execution_manager.rb` | 同名 | 无 |
| `lib/task_directory_preparer.rb` | 同名 | 仅 require 路径 |
| `app/services/report_generator.rb` / `report_html_generator.rb` | `services/report_generator.rb`、`routes/report_routes.rb` 的 HTML 生成器 | 数据源改为本应用的 Task/TaskRun/TaskExecution |
| `public/js/expandable-text.js` | 同名 | 无（原样） |
| `public/js/script-log.js` | 客户端 `views/task_detail.erb` / `views/task_report.erb` 的**内联日志逻辑** | 客户端未把它抽成 JS 模块，这里抽成公共模块：`escapeLogHtml`/`renderLog`/`createLogRefresher`，任务详情页与报告页共用 |
| `public/js/open-questions.js` | 客户端生成页「待确认」候选点击回填（内联逻辑） | 抽成公共模块 `createQuestionFiller`：点候选把【待确认#N】占位符填进描述（同一 id 多处一次全换、支持改选）；当前用于生成页「用执行日志改进」弹窗 |
| `public/js/script-result.js` | 客户端两个页面**内联的检查点/结论/状态渲染** | 抽成公共模块：`checkpointsOf`/`failedCheckpointsOf`/`passedCount`/`failedCount`/`formatCheckpoint`/`checkpointClass`/`formatConclusion`/`getScriptStatusType`/`scriptStatusText` 等，两页共用 |

**未复用（上游依赖云端/浏览器 Key）**：`public/js/cloud-improve-dialog.js`、`llm-key-store.js`。
客户端的「云端改进」是：任务日志上传云端 → 返回一次性 URL → 在**云端生成页**里做改进。
开源版保留同样的分工（改进在生成页做，不在任务页），只把"云端往返"换成**本地交接**：
任务详情日志弹窗点「改进脚本」→ 日志与检查点写入 `sessionStorage`（键 `qingxun_exec_log_handoff`）
→ 跳转脚本生成器；生成页读取交接并打开「用执行日志改进主线描述」弹窗（也可手工粘贴日志）
→ `POST /scripts/improve_description` → 预览改进后的主线描述 → 一键应用到需求描述框。

**开源版专有的薄适配层**（不含业务逻辑，仅做模型映射；上游没有对应物）：

- `app/services/task_execution_adapter.rb`：把 `Task` 映射成客户端编排层要的 `execution` 接口
  （`get_execution_units` / `update_*_status!` / `complete_from_memory!` / 目录与状态文件），
  并把状态落回 `TaskExecution` / `task_network_elements` / `TaskRun` / `Task`。
- `app/services/task_runner.rb`：建 `TaskRun` → `TaskExecutionCoordinator.new(pool_size:).submit_task` → 等结束停池。
- `app/services/device_runner.rb`：单设备单脚本的薄封装（`DeviceLoginHandler` + `ScriptExecutor`）。

**由此对齐的语义**（与客户端一致，替换了开源版早期自写实现的行为）：

- 脚本状态词表 = 客户端四态 `completed/partial/failed/error`；`TaskExecution.status` 直接存它，
  报告/状态页读 `exec.status` 与 `result['conclusion']`。
- 任务状态 = **流程**是否跑完（所有单元处理完即 `completed`，不看巡检结论）。
- 引入 `TaskRun`：1 任务 N 次执行（对齐客户端 `LocalTask` 1→N `LocalTaskExecution`、`latest_run` ≈ `latest_execution`）。
- **不支持**：运行中日志逐秒落库、执行中取消（客户端编排层都没有）。

---

## 已知待办 / 注意

- 上游若调整 `Qingxun::DeviceScript` 的沙箱能力，需同时评估 `ScriptExecutor`（真机，走 Sandbox）
  与 `DebugSession`（模拟）两处调用点。
- RSpec：开源版仍在把上游用例迁移为社区版口径（登录/识别码相关用例已移除）。

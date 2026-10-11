# frozen_string_literal: true

# 隐性知识：本文件在 summarize_mapping 里用到了 CommandMappingParser（把嵌套命令树铺平）。
# Rails 运行时靠 Zeitwerk 自动加载没问题，但纯 Ruby 单测环境不会——显式 require 一下，
# 否则单独跑 spec/services/script_evaluation_service_spec.rb 会
# uninitialized constant Prompts::ScriptEvaluation::CommandMappingParser。
require_relative '../command_mapping_parser'

module Prompts
  # 脚本评估提示词
  #
  # 设计意图（这里踩过坑）：
  #   早先的评估只给"六个维度 + 一个全局 passed"，属于整体印象式判断。后果是：
  #     1) 个别检查点（record_check）失败会被整体判断淹没；
  #     2) 失败建议是散文，下一轮生成无法"哪条不过改哪条"；
  #     3) 测试环境自身的问题（映射与真实设备行为不一致）被算到脚本头上，
  #        于是 AI 反复改写脚本去适配一个错误的 mock 回显（diagnose 事件）。
  #   现在强制**逐条评估**：先拆需求条目，逐条给证据与归因，再汇总 passed。
  module ScriptEvaluation
    # 命令映射里的响应可能是整段设备报文；评估 prompt 里只需看到"这个命令会回什么"，
    # 超长响应截断，避免 prompt 膨胀。
    MAX_MAPPING_RESPONSE_LENGTH = 800

    def self.build(description, code, command_mapping, test_result)
      checkpoints = checkpoints_of(test_result)

      <<~PROMPT
        你是一个网络设备 CLI 自动化脚本质量评估专家。请**逐条**核对生成的脚本是否完成了用户需求，并给出可核验的结论。

        ## 用户原始需求描述
        #{Prompts.escape_interpolation(description)}

        ## 生成的脚本代码
        ```ruby
        #{code}
        ```

        ## 命令映射配置（测试环境实际会回放的响应）
        ```json
        #{JSON.pretty_generate(summarize_mapping(command_mapping))}
        ```

        ## 脚本记录的检查点（record_check）
        ```json
        #{JSON.pretty_generate(checkpoints)}
        ```

        ## 测试执行结果
        ```json
        #{JSON.pretty_generate(test_result)}
        ```

        ## 评估方法（必须按此执行）

        1. **先把需求拆成条目清单**：需求里每一个"可验证的操作或判定"算一条
           （例如"下发 X 命令""回显含 Y""数值 Z 低于阈值""记录字段 A/B/C"）。
           需求中并列的多个要点必须各自成条，不能合并成一条笼统结论。
           **条目只能来自本次给出的需求描述**：描述里没有的步骤（哪怕脚本里有、
           或后续流程会用到）不要建条目，也不要为它们编造 env_mismatch / 映射建议。
        2. **逐条核对**：每条都要找到对应的检查点（record_check）与日志/报文证据，
           给出 expected（需求要求什么）和 observed（实际发生了什么）。
        3. **每条都必须给 evidence**：从执行日志或设备报文中**原文摘录**一段作为依据。
           找不到证据时，该条 passed 必须为 false，并在 note 里说明"无证据"。
        4. **失败必须归因 attribution**，取值只能是：
           - `script_issue`：脚本逻辑/解析/遗漏导致；
           - `env_mismatch`：测试环境（命令映射）与需求描述的真实设备行为不一致，
             或 mock 回显自相矛盾（例如映射里该命令响应为空、执行却报 not recognized）。
           - `needs_user_confirmation`：该条目依赖脚本与平台都拿不到的信息（如网元名称等平台元数据、
             需求未给出的判定口径/阈值），**只能由用户补充**；
           - `requirement_ambiguity`：需求本身描述不清，无法判断。
           **env_mismatch 不能算作脚本的错**：这类条目的 suggestions 只能建议
           "修正测试环境/命令映射"，**严禁**建议改写脚本逻辑去迁就错误的 mock 回显。
        5. **识别"编造字段值"（重要）**：如果脚本用字面量/占位值硬填了本应由平台提供、
           或设备回显里根本没有的字段（例如写死 `网络名称: 默认网络`、拿板卡号当网元名称、
           把型号当设备地址），这属于 `script_issue`，必须在 evidence 里引用该行代码/日志，
           并在 issues/suggestions 中明确指出"该值疑似编造，应留空或标注 [待确认]"。
           绝不能因为"字段看着填上了"就判通过。
        6. **只有真的"拿不到"才回抛用户**：只有当某条目依赖的信息**既不在本次需求描述里，
           也不在命令映射 / 设备回显 / 平台上下文中**，且需求本身也没给出判定口径或阈值时，
           才归因为 `needs_user_confirmation`，并把它转成一条**要问用户的问题**写进
           `user_questions`（问题要具体、可回答，例如"网元名称从哪里获取？请提供命名规则或设备清单"）。
           - 需求描述里**已经写明**的东西都算"已给出"，**禁止**再向用户追问，包括：
             命令、示例报文/回显、处理逻辑、阈值、基线值（如 3.72.0）、状态文案（如"跳过/skipped"）、
             正则意图等。
           - **本次描述流程之外的步骤不属于本次需求条目**，不要为它们建条目或提问
             （例如本场景在某步就结束了，就不要追问后续 show boot 等命令的报文格式）。
           - `user_questions` 只服务于 `needs_user_confirmation` 条目；**没有任何条目归因为
             needs_user_confirmation 时，`user_questions` 必须是空数组**（不得一边把失败归因成
             script_issue/env_mismatch，一边又抛出一堆"需要确认"的问题）。
           不要建议脚本自己假设一个值。
        7. **检查点为空的归因**：若脚本记录了检查点日志但导出结果里的 checkpoints 为空，
           要结合日志判断是脚本没调用 record_check 还是框架导出问题，分别归因，
           不要一律当环境问题。
        8. **命令映射补充建议 `mapping_suggestions`**：对每一个因映射缺失/错误导致的
           env_mismatch，列出需要在测试环境补充的命令映射，字段：
           - `command`：需要补充映射的原始命令（必须与脚本下发的命令逐字一致）；
           - `issue`：该命令当前的映射问题；
           - `suggested_response`：**依据需求描述中该命令的真实回显**生成的建议报文
             （需求写"收到空字符串"就填空字符串；写明了回显内容就照抄，可含换行）；
           - `reason`：依据需求原文的哪一句。
           第二轮生成会据此把映射补齐，因此这里的报文必须忠实于需求描述，不能凭空编造。
        9. **passed 判定**：仅当所有需求条目都 passed=true 时才为 true；
           任何一条未通过都必须为 false。不允许"个别条目失败但整体通过"。
           存在 `needs_user_confirmation` 条目时也必须为 false（信息不足，无法确认达成）。
           **注意**：这里的"需求条目"只指本次需求描述拆出的条目。若你顺带发现与本次需求无关的
           问题（例如代码其他环节的硬编码、判定过宽），写进 issues/suggestions 并标注
           "非本次需求范围"即可，**不得**因此把 passed 置为 false，也不要为它们新增 items。

        ## 逐条判断时的检查维度
        - 用户目标达成度：结果语义上是否真的完成了需求（设备报错/操作未成功 = 未达成）。
        - 需求符合度：需求条目是否都有对应实现，有无遗漏。
        - 执行正确性：测试是否成功执行，返回值是否合理。
        - 日志分析：关键数值/状态是否用 log_info 记录，中间结果是否可核验。
        - 输出合理性：返回值结构是否清晰、有意义。
        - record_check 使用：必填参数 name/passed 是否正确；需求条目是否有检查点覆盖。
        - 代码结构（仅作为 issues 提示，不单独成条目、不影响 passed）：所有 `connection.cli`
          是否集中在主函数 `run`；报文解析与检查是否拆成独立的解析/检查函数；解析/检查函数
          上方是否有输入/输出样例注释。发现不符合时写入 issues，供后续迭代整理。
          **不要**因为脚本用 `log_info` 记录了端口清单、CPU 数值这类解析/筛选结果就判为
          "冗余日志"——中间结果是上面「日志分析」维度要求记录的，也是你取证要靠的东西；
          禁止的是把整段设备回显原文搬进日志（那由生成侧规则约束，不在这里重复判）。
          同理，`log_info("[步骤N] 开始：…")` / `log_info("[步骤N] 结束")` 这类**步骤边界日志**
          是需求明确要求写进日志的（客户端靠它看进度），**不得**判为冗余日志或噪音。

        ## 输出格式（严格 JSON，不要输出 JSON 以外的文字）
        ```json
        {
          "items": [
            {
              "requirement": "需求条目原文或摘要",
              "checkpoint": "对应的 record_check 名称，没有则填 null",
              "passed": true,
              "expected": "需求期望",
              "observed": "实际结果",
              "evidence": "日志或报文原文片段",
              "attribution": "ok 或 script_issue 或 env_mismatch 或 needs_user_confirmation 或 requirement_ambiguity",
              "note": "补充说明，可为空"
            }
          ],
          "passed": false,
          "evaluation": "总体分析：哪些条目通过、哪些未通过、根因是什么",
          "issues": ["问题1", "问题2"],
          "suggestions": ["建议1", "建议2"],
          "env_mismatches": ["测试环境/映射与真实设备不一致之处"],
          "user_questions": ["需要向用户确认的具体问题（针对 needs_user_confirmation 条目）"],
          "mapping_suggestions": [
            {
              "command": "需要补充映射的原始命令",
              "issue": "当前映射的问题",
              "suggested_response": "依据需求描述该命令应回放的报文（可为空字符串）",
              "reason": "依据需求原文的哪一句"
            }
          ]
        }
        ```

        **最后再确认六条硬性要求**：
        1. items 要覆盖需求里的每一条，不能只给一条笼统结论；
        2. 每条都要有 evidence，无证据的条目不得判通过；
        3. 归因为 env_mismatch 的失败，建议只能指向"修测试环境映射"，不要建议改脚本去适配错误回显；
        4. 发现脚本用字面量/占位值硬填无来源字段时，必须判 script_issue 并指出"疑似编造"；
        5. 只有条目归因 needs_user_confirmation 时才在 user_questions 里给出要问用户的具体问题；
           需求里已写明、或本次描述范围之外的信息不要追问，没有这类条目时 user_questions 必须为空；
        6. passed 只有在 items 全部通过时才为 true；与本次需求无关的问题（放 issues 并注明"非本次需求范围"）
           不得影响 passed，也不要放进 items。
      PROMPT
    end

    def self.system_prompt
      '你是一个网络设备 CLI 自动化脚本质量评估专家。你必须把用户需求拆成条目、逐条核对并给出证据，' \
        '区分"脚本问题"与"测试环境问题"，且只有全部条目通过时才能判定整体通过。' \
        '与本次需求无关的问题只作为参考写入 issues，不得影响整体通过判定。'
    end

    # 命令映射摘要：超长响应截断，避免 prompt 被设备报文灌满。
    #
    # 隐性知识：
    #   映射可能是嵌套的上下文树（同一命令在不同上下文下回显不同），必须摊平后逐条列出，
    #   否则子树里的回显会被整段丢掉，评估模型会把"映射里有、只是没在根层"误判成
    #   env_mismatch。带上 context（如 "root > switch board 1"）让模型知道回显属于哪一层。
    def self.summarize_mapping(command_mapping)
      CommandMappingParser.flatten(command_mapping).map do |entry|
        response = entry[:response].to_s
        if response.length > MAX_MAPPING_RESPONSE_LENGTH
          response = "#{response[0, MAX_MAPPING_RESPONSE_LENGTH]}……（已截断，原长 #{response.length} 字符）"
        end

        summary = { command: entry[:command], response: response }
        context = entry[:context_path]
        summary[:context] = context if context.present? && context != 'root'
        summary
      end
    end

    # 从测试结果里取出脚本记录的检查点（脚本若 return build_script_result 就会带上）。
    # result 可能是 ScriptResult 对象（沙盒内直接用），也可能是序列化后的 Hash（文件/接口），两种都要兼容。
    def self.checkpoints_of(test_result)
      return [] unless test_result.is_a?(Hash)

      result = test_result[:result] || test_result['result']
      return [] if result.nil?

      checkpoints =
        if result.is_a?(Hash)
          result[:checkpoints] || result['checkpoints']
        elsif result.respond_to?(:checkpoints)
          result.checkpoints
        end

      return [] unless checkpoints.is_a?(Array)

      checkpoints.map { |c| c.respond_to?(:to_h) ? c.to_h : c }
    end
  end
end

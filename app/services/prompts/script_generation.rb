# frozen_string_literal: true

module Prompts
  module ScriptGeneration
    # 构建脚本生成的完整提示词
    def self.build(error_history, enhanced_description, feedback = nil)
      error_section = error_history.empty? ? "" : "\n\n之前的尝试出现错误，请修正：\n#{Prompts.escape_interpolation(error_history)}"
      feedback_section = feedback ? "\n\n外部反馈和改进建议：\n#{Prompts.escape_interpolation(feedback)}" : ""

      <<~PROMPT
        脚本示例（注意结构：所有命令只在主函数 run 里下发，报文解析与检查各自独立成函数，
        并在注释中给出输入/输出样例）：
          ```ruby
          # frozen_string_literal: true
          require 'qingxun'

          module QingxunScript
            class HealthCheck < Qingxun::DeviceScript
              CPU_THRESHOLD = 80

              # 主函数：所有 connection.cli 下发命令都集中在这里，按流程顺序执行
              def run(connection)
                record_start!
                log_info("开始设备健康检查...")

                cpu_output = connection.cli("display cpu-usage")
                check_cpu_usage(parse_cpu_usage(cpu_output))

                fan_output = connection.cli("display fan")
                check_fan_states(parse_fan_states(fan_output))

                log_info("健康检查完成")
                build_script_result
              end

              # 解析 CPU 利用率报文（只做解析，不下发命令）
              #
              # 输入样例（connection.cli("display cpu-usage") 返回的报文原文）：
              #   "CPU usage in 5 seconds: 20%\\nCPU usage in 5 minutes: 30%\\n"
              # 输出样例：
              #   { "five_seconds" => 20, "five_minutes" => 30 }
              # 解析失败时：返回 {}，调用方据此判失败
              def parse_cpu_usage(output)
                text = output.to_s
                result = {}
                if text.match(/5 seconds[:\\s]+(\\d+)%/)
                  result["five_seconds"] = Regexp.last_match(1).to_i
                end
                if text.match(/5 minutes[:\\s]+(\\d+)%/)
                  result["five_minutes"] = Regexp.last_match(1).to_i
                end
                result
              end

              # 检查 CPU 利用率是否低于阈值，并记录检查点
              #
              # 输入样例：
              #   { "five_seconds" => 20, "five_minutes" => 30 }
              # 输出样例（内部调用 record_check 记录，返回判定结果）：
              #   check_cpu_usage({ "five_minutes" => 30 })  #=> true
              #   （等价于 record_check("检查CPU利用率", true, value: 30, expected: "5分钟均值 < 80%")）
              # 解析失败时（输入 {}）：record_check(..., false, reason: "无法解析CPU输出")，返回 false
              def check_cpu_usage(cpu)
                value = cpu["five_minutes"]
                passed = !value.nil? && value < CPU_THRESHOLD
                record_check("检查CPU利用率", passed,
                  value: value,
                  description: "验证CPU利用率不超过阈值",
                  command: "display cpu-usage",
                  expected: "5分钟均值 < #\{CPU_THRESHOLD\}%",
                  reason: passed ? nil : (value.nil? ? "无法解析CPU输出" : "CPU过高: #\{value\}%"),
                  suggestion: passed ? nil : "检查异常进程")
                passed
              end

              # 解析风扇状态报文（只做解析，不下发命令）
              #
              # 输入样例：
              #   "Fan 1: Normal\\nFan 2: Fault\\n"
              # 输出样例：
              #   { "Fan 1" => "Normal", "Fan 2" => "Fault" }
              # 解析失败时：返回 {}
              def parse_fan_states(output)
                result = {}
                output.to_s.each_line do |line|
                  if line.match(/^(Fan\\s+\\d+):\\s*(\\S+)/)
                    result[Regexp.last_match(1)] = Regexp.last_match(2)
                  end
                end
                result
              end

              # 检查风扇是否全部 Normal，并记录检查点
              #
              # 输入样例：
              #   { "Fan 1" => "Normal", "Fan 2" => "Fault" }
              # 输出样例（内部调用 record_check 记录，返回判定结果）：
              #   check_fan_states({ "Fan 1" => "Normal", "Fan 2" => "Fault" })  #=> false
              #   （等价于 record_check("检查风扇状态", false, reason: "检查到以下风扇有问题：Fan 2、Fan 5（Fault）")）
              def check_fan_states(states)
                bad = states.reject { |_name, state| state == "Normal" }
                passed = states.any? && bad.empty?
                # 失败原因按原因归并、同类对象并列，不要把每个对象的描述各抄一句
                reason = passed ? nil : "检查到以下风扇有问题：" +
                  bad.map { |name, _state| name }.join("、") +
                  "（" + bad.map { |_name, state| state }.uniq.join("、") + "）"
                record_check("检查风扇状态", passed,
                  description: "检查所有风扇运行状态",
                  command: "display fan",
                  expected: "所有风扇状态为 Normal",
                  reason: reason)
                passed
              end
            end
          end
          ```

          关键规则：
          1. **命令下发与检查记录的关系**
             - 所有 `connection.cli()` 必须在主函数 `run` 中执行，按流程顺序下发；
             - 报文解析交给独立的解析函数，判定与 `record_check` 交给独立的检查函数（见第 19-21 条）；
             - 解析出的关键数值/状态用 `log_info` 记录，便于评估核对。
          2. **record_check 正确用法（非常重要）**：
             - 前两个参数是位置参数，不能用 Hash：`record_check("名称", true/false, **kwargs)`
             - 第一个参数：name（字符串，位置参数）
             - 第二个参数：passed（布尔值，位置参数）
             - 其他参数：关键字参数（value:, description:, command:, expected:, reason:, suggestion:）
             - 错误示例：`record_check({name: "xxx", passed: true})` 错误！
             - 正确示例：`record_check("xxx", true, description: "yyy", command: "zzz")`
             - **一个检查点覆盖多个对象（端口/接口/风扇/进程等）时，只调用一次 record_check**：
               禁止在循环里逐个对象调用，否则报告里会出现 N 条几乎一样的失败项。
             - **失败原因先按原因归并、同类对象并列，同一句话只说一次。**
               反例（错）："smartgroup11 缺少 lldp-tx disable nearest-bridge;
                smartgroup12 缺少 lldp-tx disable nearest-bridge;
                smartgroup13 缺少 lldp-tx disable nearest-bridge"
               正例（对）："检查到以下聚合口有问题：smartgroup11、smartgroup12、smartgroup13
                （缺少 lldp-tx disable nearest-bridge）"
             - **失败对象 ≥5 个时，reason 只写摘要并指向日志，完整清单用 log_info 落日志**：
               先用 `log_info` 逐条输出完整清单（一行一个对象，便于对方排查），例如
               `log_info("以下聚合口缺少 lldp 关闭配置: smartgroup11 (缺 lldp-tx); smartgroup12 (缺 lldp-rx、lldp-tx)")`；
               再让 reason 给出摘要 + 总数 + 去哪看，例如
               "检查到 12 个聚合口缺少 lldp 关闭配置（缺 lldp-tx disable nearest-bridge）：
                smartgroup11、smartgroup12、smartgroup13 等 12 个；完整清单见执行日志"。
               省略掉的部分必须能在日志里查到 —— 不要 reason 里一半、日志里一半。
             - `value` 只放一句结论式摘要（如 "41 个 mc-lag 聚合口中 12 个缺少 lldp 关闭配置"），
               不要把 reason 的清单再抄一遍。
          3. **必须使用用户提供的真实响应来写正则！！！**
             - 仔细分析用户提供的"真实响应"
             - 不要臆测输出格式
             - 正则表达式必须精确匹配真实输出
          4. **只记录解析出的关键值，不要记录原始回显**
             - 框架会自动记录每条命令的"下发命令 / 收到报文"，因此**禁止**再写
               `log_info("xxx 回显: #\{output.inspect\}")` 这类把整段原始报文抄一遍的日志；
             - 需要记录的是**解析出来的数值、状态与结论**，例如
               log_info("解析到CPU利用率: #\{cpu\}%")、log_info("Base版本低于基线，不支持内存检查")。
             - 日志要清晰说明解析出的是什么值，便于评估核对。
          4.1 **步骤边界日志（要求的一部分）**：需求描述用
              `----------------------步骤N----------------------` 标出了执行步骤，脚本要在
              **每一步的开始与结束各写一条 log_info**，让客户端日志里能一眼看出当前走到哪一步：
              `log_info("[步骤3] 开始：<该步骤的标题>")` … 该步骤的命令与检查 … `log_info("[步骤3] 结束")`
             - 编号与描述里的步骤号一致；描述里没有步骤标记时，按 `run` 里的执行顺序从 1 开始连续编号；
             - 该步骤的命令下发与 record_check 都要落在这两条日志之间；
             - 步骤边界日志属于**要求的一部分**，不与第 4 条冲突（第 4 条禁止的是把整段原始报文
               抄进日志，不是禁止写步骤边界）。
          5. **标准模板**：开头调用 record_start!，结尾调用 build_script_result
          6. **类名**：采用驼峰命名的 **ASCII** 标识符（如 HealthCheck）。脚本名称可以是中文，
             但**类名不要出现中文或其它非 ASCII 字符**——类名要跟着脚本文件、日志、客户端
             一起走，保持 ASCII 才不会在某一环被转义或截断
          7. **QingxunScript 模块**：所有脚本类必须定义在 QingxunScript 模块内部
          8. **require 'qingxun'**：必须使用下划线
          9. **用户输入的命令和响应必须原文引用**
          10. **不要使用不存在的常量**
          11. **禁止过度设计，禁止预留接口**
          12. **由于scan函数在进行超长字符串匹配复杂正则表达式时容易出现死循环，尽量使用其他方式实现**
          13. **用户提示词中如果提供了`解析函数`或者其他函数api，可直接使用**
          14. **如果环境报错必须按照脚本错误处理，这是一个整体**
          15. **脚本可用的上下文只有这些**：`connection`（CLI 交互对象）与 `device_config`（设备配置哈希，可读 `device_config[:host]` 等）。
              调试环境下 `device_config` 通常只有 host/port/username/password/enable_password；真实执行时可能还带 name/device_model。
              除此之外**没有任何全局变量、环境变量或外部数据源**，也不要访问 ENV / File / 网络。
          16. **严禁编造字段值**：需求要求记录的字段如果既不在设备回显里、也不在 `device_config` 里，
              **绝对不要填假值或占位值**。正确做法：
              - 能取到就填真实值；
              - 取不到就留空，并在日志里明确写 `字段名: [待确认]`；
              - 或用 `record_check(..., passed: false, reason: "缺少数据来源：xxx", suggestion: "请用户提供 xxx")` 标记为待确认。
              反例（严重）：写死 `网络名称: 默认网络`、拿板卡号当网元名称、把型号当设备地址——
              这类"看起来填上了"的假值比留空更糟，会让用户误以为数据是真的。
          17. **拿不准就回抛用户，不要自己拍板**：字段来源、判定口径、阈值等需求里没写清时，
              不要自行假设一个值去"做圆"；把它标成待确认项（见第 16 条），由平台反馈给用户确认。
          18. **不要为了通过检查而绕过**：不允许为了让检查点变绿而放宽断言、吞掉异常或伪造数据；
              真实失败就如实记录失败。
          19. **结构要求：所有下发命令集中在主函数**
              - 所有 `connection.cli(...)` 调用都必须写在主函数 `run` 里，按流程顺序执行；
              - 解析函数与检查函数**一律不下发命令**（不接收 connection、不调用 cli）。
          20. **结构要求：报文分析与检查另写函数**
              - `run` 里不要写正则/字符串解析与 record_check 逻辑；一个命令对应
                "解析函数 + 检查函数"各一个，职责单一：
                · 解析函数：输入报文，只输出结构化数据；
                · 检查函数：输入结构化数据，做判定并调用 record_check。
              - `run` 负责按顺序下发命令，并把"解析函数的输出"交给"检查函数"。
          21. **解析/检查函数必须在注释中写输入输出样例**
              - 每个解析/检查函数上方用注释给出：
                · 输入样例（真实报文原文，或结构化数据）；
                · 输出样例（返回的结构，或 record_check 的判定结果）；
                · 解析/判定失败时的返回或行为。
              - 样例要贴合本次需求的真实报文，禁止写"示例文本""xxx"这类占位。
          22. **需求里列出的每条命令都必须由脚本下发（重要）**
              - 需求/手工日志里作为步骤出现的**每一条命令**，都要通过 `connection.cli(...)`
                由脚本下发，包括登录/建连（`ssh xxx`）、进入容器（`docker exec ... /bin/sh`）、
                切目录（`cd`）、终端设置（`terminal length 0`）这类看起来"不是业务命令"的动作。
                不要因为"它像是环境准备""连接应该由框架负责"就把它省掉——需求把它列成了步骤，
                就说明要由脚本执行；
              - **唯一的例外**：需求里**明确写了**该步骤不需要下发（例如注明"由环境预先完成，
                脚本无需执行"）。需求没有明确说不需要，就必须下发；
              - 命令参数用到前面回显里解析出的值时（例如容器 ID），在 `run` 里用变量拼出完整
                命令后下发，不要因为"参数是动态的"就把整条命令省掉。

          23. **需求里的「预期」是给评估用的判定口径，不是脚本要比对的期望值（重要）**
              - 需求描述里的「预期」写的是"什么算通过"，供**评估方**判断脚本是否达成；脚本
                **不得把预期里（或需求/手工日志样例回显里）出现的具体结果值写成比较常数**。
                例如需求写"预期：本回显应得到 Gi0/2、Gi0/4"，脚本**不能**写
                `passed = bad_ports == ["Gi0/2", "Gi0/4"]`——换一台设备非 connected 端口
                不同，正常的脚本会被判成失败；
              - 正确做法是把预期实现成"解析 + 按规则判定"：解析出结构化数据 → 按需求给的判定
                规则（状态字面量、阈值、正则）算出结果 → 结果写进 `record_check` 的 `value`，
                `expected` 写判据本身（如"列出所有 Status 不为 connected 的端口"），
                不要写死具体的端口/数值清单；
              - **要区分"规则常量"与"某次回显的结果值"**：规则本身包含的常量（状态字面量
                `connected`、阈值 `80%`、正则）换台设备也成立，该用就用；而某次回显里恰好
                出现的端口名、清单、实测数值（如 `12%`）只对那一次回显成立，既不能当期望值，
                也不能拿它反推阈值或上下界；
              - 需求只给了样例值、没给判据时，按「处理逻辑」写的规则实现，把样例值当作该规则
                的一个实例，不要当作期望。

          24. **表格类回显按表头定位字段（优先于写死列宽与状态枚举）**
              - 回显里带表头行时（如 `show interfaces status` 的
                `Port    Name    Status    Vlan    Duplex  Speed`），先解析表头，拿到每个字段
                的**列位置**（起始列或列区间），再按该位置从数据行切出字段值。不要把列偏移、
                固定列宽、或"按空白切分后取第 N 段"写死——换个型号或软件版本的设备，列宽、
                列顺序、字段数都可能不同；
              - **按空白切分在表格里一定会错位**：`Name` 为空的行（如
                `Gi0/2                 notconnect   10     auto    auto`）切出来的段数比表头少，
                后面所有字段都会错位一列。列位置必须按表头行的实际字符位置算；
              - **解析时不要用状态枚举白名单**：不要写
                `status =~ /^(connected|notconnect|disabled|err-disabled)$/` 这类白名单来
                **识别**状态列——状态文案因设备而异（`connected`/`up`/`notconnect`/`down`/
                `suspended`…），枚举必然漏，漏了就整行解析失败。状态值按表头定位整列原样取出，
                **判定**再用需求给出的口径（例如"Status ≠ connected"，这个 `connected`
                是判定口径里的常量，该用就用，见第 23 条）；
              - 表头缺失或不可靠时（有的设备不输出表头）才退化为按列位置/正则解析，并在函数
                注释里写明退化依据。

          用户需求：
          ```
          #{Prompts.escape_interpolation(enhanced_description)}
          ```

          同时生成命令映射 JSON 对象（用于自动测试）：
          #{Prompts.command_mapping_format_guide}
          **命令映射中的内容必须全文引用用户的输入**

          输出格式：
          1. 首先输出 Ruby 代码，包含在 ```ruby 代码块中。
          2. 然后输出命令映射 JSON，包含在 ```json 代码块中。
          3. 然后输出脚本名称，包含在 ```script_name 代码块中：**用中文**、简短（不超过 20 个字），
             例如"接口状态与CPU巡检"。不要输出 `PortCpuCheck` 这类英文标识符式的名字——
             类是代码里的类名，这里是给用户看的显示名，两者不必一致。
          4. 最后用一句话总结脚本功能，包含在 ```description 代码块中。

          代码块之间用空行分隔。

          请确保 Ruby 代码语法正确，JSON 格式有效。#{error_section}#{feedback_section}
        PROMPT
      end

    # 构建"微调现有脚本"的提示词。
    #
    # 业务逻辑：
    #   用户在页面上修改了主线/分支描述后点「微调」，此时不应该按描述从零重写，而要在
    #   **现有代码**基础上做最小必要改动来适配当前描述，并重新产出命令映射。
    #
    # 隐性知识：
    #   - 必须显式声明"微调不是重写"，否则模型容易整篇重写，丢失用户已验收的细节。
    #   - 分支描述在生成模式下只用于测试；微调模式下要把它们交给模型，因为用户改的
    #     往往正是分支内容，代码需要据此调整。
    #   - 输出仍是完整的四段代码块（ruby/json/script_name/description），这样能直接复用
    #     现有的抽取、语法校验与映射解析逻辑。
    def self.build_refine(existing_code:, mainline_description:, branches: [], error_history: nil, feedback: nil)
      error_section = error_history.present? ? "\n\n上一轮测试未通过，请修正：\n#{Prompts.escape_interpolation(error_history)}" : ""
      feedback_section = feedback.present? ? "\n\n外部反馈和改进建议：\n#{Prompts.escape_interpolation(feedback)}" : ""

      branch_lines = Array(branches).each_with_index.map do |branch, index|
        name = branch[:name] || branch['name']
        desc = branch[:description] || branch['description']
        "分支#{index + 1}「#{name}」：\n#{desc}"
      end.join("\n\n")

      branch_section = if branch_lines.present?
                         "\n\n当前各分支描述（代码要能应对这些场景）：\n#{Prompts.escape_interpolation(branch_lines)}"
                       else
                         ""
                       end

      <<~PROMPT
        【微调现有脚本】下面是已经生成的脚本代码：

        ```ruby
        #{existing_code}
        ```

        用户在原需求描述上做了修改，现在的主线需求是：
        ```
        #{Prompts.escape_interpolation(mainline_description)}
        ```#{branch_section}

        请在这份现有代码的基础上做**最小必要改动**，使它适配上面的当前主线与分支描述。

        微调规则（必须遵守）：
        1. 这是**微调，不是重写**：只改动与本次描述变更相关的命令、解析逻辑、检查点或日志；
           与本次变更无关的部分（其他命令、函数、record_check、日志格式等）尽量原样保留。
        2. 不要调整类名与 QingxunScript 模块等结构；不要引入用户没要求的新功能。
        3. 如果当前描述与现有代码冲突，以当前描述为准，但仍不要推倒重来。
        4. 仍要满足主线与全部分支描述：分支描述代表代码必须能应对的场景，改动要覆盖它们。
        5. 继续遵守原有的 record_check 用法与命令-报文映射约定。
        6. 保持并补齐代码结构：所有 `connection.cli` 下发命令只在主函数 `run` 中；
           报文解析与检查拆成独立的解析函数/检查函数；每个解析/检查函数上方注释给出
           输入/输出样例。若现有代码不符合该结构，微调时一并整理（可只做结构调整，不必改变行为）。
        7. 不要用 `log_info` 记录原始回显/整段报文（框架会自动记录"下发命令 / 收到报文"）；
           现有代码里若有这类冗余日志，一并删除，只保留解析出的关键值/结论日志。
        7.1 **步骤边界日志**：需求描述里的 `----------------------步骤N----------------------` 要有对应的
           `log_info("[步骤N] 开始：<标题>")` 与 `log_info("[步骤N] 结束")`，命令与检查落在这两条之间。
           现有代码已经有这些日志的，**保留编号与写法**；本次改动新增或合并了步骤，就补上对应的两条，
           不要重排既有编号（编号乱了，客户端日志与需求就对不上了）。
        8. 需求/手工日志里作为步骤出现的**每条命令都必须由脚本下发**（含登录/建连、进入容器、
           切目录、终端设置这类）；发现现有代码漏发了某条步骤命令，一并补上——唯一的例外是
           需求里明确写了该步骤不需要下发。
        9. 不得把需求「预期」或样例回显里的具体结果值写成比较常数（发现现有代码里已经这么写了，
           一并改掉）：例如把非 connected 端口清单写死成 `["Gi0/2", "Gi0/4"]`，换一台设备就会
           误判为失败。预期是给评估用的判定口径；脚本要按规则（状态字面量、阈值、正则）解析
           并判定，`record_check` 的 `expected` 写判据本身。规则里本身就有的常量（如状态字面量
           `connected`、阈值 `80%`）换台设备也成立，该用就用。
        10. 表格类回显一律按**表头定位字段**：先解析表头拿列位置，再按位置从数据行取值；
           不要写死列宽、列偏移或"按空白切分取第 N 段"（`Name` 为空的行会错位），也不要用
           状态枚举白名单去匹配判定值。发现现有代码是写死列宽/枚举解析的，一并改为表头定位。

        同时重新生成与改动后脚本一致的命令映射 JSON（用于自动测试）：
        #{Prompts.command_mapping_format_guide}
        **命令映射中的内容必须与当前需求描述一致**

        输出格式（务必输出完整脚本，不要只输出 diff）：
        1. 首先输出完整的 Ruby 代码，包含在 ```ruby 代码块中。
        2. 然后输出命令映射 JSON，包含在 ```json 代码块中。
        3. 然后输出脚本名称，包含在 ```script_name 代码块中：**用中文**、简短（不超过 20 个字），
           例如"接口状态与CPU巡检"；沿用原脚本名称的中文风格，不要改成英文标识符。
        4. 最后用一句话总结脚本功能，包含在 ```description 代码块中。

        代码块之间用空行分隔。

        请确保 Ruby 代码语法正确，JSON 格式有效。#{error_section}#{feedback_section}
      PROMPT
    end

    # System prompt 用于脚本生成
    def self.system_prompt
      <<~PROMPT
        角色：
          你是一个网络设备 CLI 自动化脚本专家。专门为安全沙盒环境生成 Ruby 脚本。
          你的任务是根据用户需求生成使用 Checkpoint 模式的脚本，脚本必须继承自 Qingxun::DeviceScript 类。
          同时，为脚本中执行的 CLI 命令生成命令-响应映射（用于自动测试）。

        【最重要】必须使用用户提供的真实响应来写正则表达式！！！

        Code Structure (Strict Adherence Required):
          1. 所有 connection.cli(...) 下发命令必须集中在主函数 run 中，按流程顺序执行；
             解析/检查函数不下发命令。
          2. 报文解析与检查逻辑必须拆成独立的函数，不得写在 run 里：
             - 解析函数：输入报文，输出结构化数据；
             - 检查函数：输入结构化数据，做判定并调用 record_check。
          3. 每个解析/检查函数上方必须写代码注释，给出输入样例与输出样例
             （以及解析/判定失败时的行为）；样例要基于本次需求的真实报文，不得用占位文本。
          4. 不要用 log_info 记录原始回显/整段报文——框架会自动记录"下发命令 / 收到报文"；
             只记录解析出的关键数值、状态与结论。
          5. 类名用 **ASCII** 驼峰（如 HealthCheck），不要出现中文或其它非 ASCII 字符：
             类名要跟着脚本文件、日志、客户端一起走。脚本的**显示名**可以是中文，两者互不影响。

        Security Protocol (Strict Adherence Required):
          禁止的本地系统操作：
            - 禁止执行系统命令（system, exec, spawn, IO.popen, 反引号, %x{}）
            - 禁止文件系统访问（File, IO, Dir）
            - 禁止访问 ENV 对象
            - 禁止建立新的网络连接（Net::HTTP, Socket 等），只能通过 connection 对象与设备通信

          禁止的危险网络命令：
            - 系统破坏：rm, delete, format, erase
            - 执行重启：reload, reboot, restart
            - 配置变更：write, copy running-config startup-config（除非用户明确要求）
            - 权限提升：configure terminal（仅限巡检类任务，需用户显式授权）

          Safety Check:
            在输出代码前，确认：
            - 不读取本地文件？
            - 不包含 reload/reboot？
            - 不用反引号执行系统命令？
            - 正则是基于真实响应写的？
            - 有没有编造无数据来源的字段值？（有则改为留空并标 [待确认]，绝不填假值）
            - 有没有把拿不准的地方自己假设、而不是标成待确认项反馈给用户？

        #{CustomIntegration::PromptMethods.system_prompt}
      PROMPT
    end
  end
end

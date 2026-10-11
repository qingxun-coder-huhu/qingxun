# frozen_string_literal: true

# 隐性知识：这里显式 require 各提示词文件。
#   原先它们是由 prompts/pair_programming.rb 链式带进来的；结对编程移除后那条链断了，
#   纯 Ruby 环境（不加载 Rails/Zeitwerk 的单测）下 `Prompts::ScriptEvaluation` 等常量
#   就会 undefined。Rails 运行时有 Zeitwerk 自动加载不依赖此处，但显式 require 同时
#   覆盖单测环境，且与改动前的行为一致。
require_relative 'prompts/auto_generate'
require_relative 'prompts/branch_consistency'
require_relative 'prompts/branch_mapping'
require_relative 'prompts/branch_suggestion'
# requirement_draft 定义 MAX_OPTIONS，description_improvement 在类体里引用它，须先加载
require_relative 'prompts/requirement_draft'
require_relative 'prompts/description_improvement'
require_relative 'prompts/requirement_enhancement'
require_relative 'prompts/script_evaluation'
require_relative 'prompts/script_generation'
require_relative 'prompts/task_creation'

# Prompts 模块 - 统一管理项目中的所有 LLM 提示词
#
# 业务逻辑：
#   - 集中管理所有 system 和 user prompt
#   - 提供统一的字符串转义等辅助方法
#   - 便于 prompt 的版本管理和迭代优化
#
# 隐性知识：
#   - 所有 prompt 应该通过这个模块访问，避免散落各处
#   - 通用的安全策略、格式要求可以在基础模块中定义
#
module Prompts
  # 转义字符串中的 Ruby 插值语法，防止在提示词构建时被意外解释
  #
  # 隐性知识：**给模型读的代码不要用它**。它把 `#{` 改成字面量 `\#{`，而模型是照着自己看到的
  # 文本推理的：实测把脚本代码转义后嵌进评估提示词，评估就连续报"log_info 使用了转义字符串
  # \#{...}，双引号内不会插值"——用户去查代码却查不到，因为代码里本来就是 `#{`（9/13–9/25
  # 累计 21 条这类假问题，而生成侧回复里字面量 `\#{` 出现 0 次）。对运行时插入的字符串来说
  # 这个转义本身也是多余的：`#{str}` 插入的是字符串的值，Ruby 不会再解释一遍；真正需要写
  # `#\{` 的是 heredoc 源码内部（提示词源码里本来就是那么写的）。所以嵌代码一律直接
  # `#{code}`，本方法只留给散文类内容（用户目标、手工日志、需求描述、反馈）。
  def self.escape_interpolation(str)
    return '' if str.nil?
    str.to_s.gsub('#{', '\#{')
  end

  # 清理代码块标记（通用方法）
  def self.strip_code_blocks(str)
    return '' if str.nil?
    str = str.to_s.strip
    str.gsub(/\A```(?:json|ruby|text|markdown)?\s*/, '').gsub(/```\s*\z/, '').strip
  end

  # 命令映射 JSON 的嵌套格式与规则说明（脚本生成、微调、分支映射共用）。
  #
  # 业务逻辑：
  #   模拟器支持嵌套的命令树：命中带 children 的命令即进入下一层上下文，因此同一命令
  #   在不同上下文下可以有不同的回显（典型场景：不同单板、不同目录下执行相同的命令）。
  #
  # 隐性知识：
  #   children / mock 是**仅测试模拟器使用**的导航元数据。必须显式声明这一点，否则
  #   模型可能把它们当成真实 CLI 参数写进脚本。同时必须强调"没有上下文差异就不要嵌套"，
  #   否则模型会为了形式上的树形而过度嵌套，反而更容易生成错。
  def self.command_mapping_format_guide
    <<~GUIDE
      命令映射 JSON 支持嵌套：默认仍是平铺的 commands 列表；只有当**同一个命令在不同
      上下文下回显不同**（例如不同单板、不同目录下执行相同的 ls 命令），或需要
      "进入/退出某个层级"时才使用 children 建子树。

      格式：
      {
        "commands": [
          { "command": "show version", "response": "全局命令的回显，只写在根层即可" },
          { "command": "switch board 1",
            "response": "进入该层时的回显，可为空字符串",
            "children": [
              { "command": "ls", "response": "该层下 ls 的回显" },
              { "command": "cd card2", "response": "",
                "children": [ { "command": "ls", "response": "更深一层 ls 的回显" } ] },
              { "command": "exit", "response": "", "mock": { "exit_level": 1 } }
            ] }
        ]
      }

      规则：
      1. 命中带 children 的命令即进入下一层上下文；children 里写"进入后可用"的命令，
         进入命令本身写在父节点上。
      2. 退出命令用 mock.exit_level 精确声明退几层：1 = 回上一层，0 = 回根层。
         各上下文按真实设备行为分别声明（有的回上一层、有的回根）；若只需"默认回根"，
         在根层放一条 { "command": "exit", "response": "", "mock": { "exit_level": 0 } } 兜底。
      3. 命令查找是"就近优先、逐级向上兜底到根"：全局命令（如 enable、show version）
         只写在根层，任何上下文都能命中，不必每层重复。
      4. **命令与回显都不许带提示符**：command 只写裸命令（`show version`，不是
         `Switch> show version`），response 只写设备输出本身，不要包含提示符行或提示符前缀。
         脚本要跑在不同设备上，各家提示符都不一样（`Switch>`、`slot1>`、`(config)#` …），
         把某台设备的提示符固化进映射会误导后续生成的脚本。映射里没有、也不需要
         任何与提示符相关的字段——提示符由模拟器自己决定，与映射无关。
      5. children / mock 是**仅测试模拟器使用**的导航元数据：真机不认识它们，生成的脚本里
         绝不能出现这些字段，脚本下发的命令也不因此改变。
      6. **response 只能逐字取自用户描述原文**。描述里给了该命令的回显就照抄（保留空格、
         换行、单位），描述里没有逐字给出该命令的回显时——例如只写了"登录 banner，不解析"、
         或只写了输出摘要——**就留空字符串**（空字符串是合法回显，表示该命令无回显）。
         **严禁凭常识补一段看起来真实的回显**：不要编造版本号、IP、主机名、时间戳、
         更新条数这类具体值，哪怕它"看起来就该是这样"。编出来的假回显会与真实设备不一致，
         测试却对着它变绿，比留空危险得多。
      7. 没有上下文差异的命令一律保持平铺，不要为了"看起来像树"而强行嵌套。
      8. **命令之间有依赖时，派生命令要写出具体形式**：若某条命令的参数来自前面回显里
         提取的值（例如从 `show alarm` 回显里解析出端口号 `port3`，再执行
         `show optical port3`），映射里必须写出脚本**实际会下发的那条具体命令**
         （`show optical port3`）；只写不带参数、或写成通配的 `show optical` 都匹配不上，
         脚本会拿到 "Command ... not recognized."。模拟回显是固定的，派生出来的值也就确定，
         这些命令可以逐条枚举；用户日志里出现过就照抄原样。
      9. **映射要覆盖脚本会下发的每一条命令**，包括登录/建连（`ssh xxx`）、进入容器
         （`docker exec ... /bin/sh`）、切目录（`cd`）、终端设置（`terminal length 0`）
         这类看起来"不是业务命令"的动作——它们同样由脚本下发。漏掉任何一条，脚本跑到那里
         就会拿到 "Command ... not recognized."，测试会以与被测需求无关的方式失败。
    GUIDE
  end
end

# frozen_string_literal: true

module Prompts
  # 分支一致性检查提示词
  #
  # 业务逻辑：
  #   把「主线需求描述」与「各分支场景描述」交给模型逐条比对，判断分支是否
  #   **超出主线要求（超纲）**或**与主线矛盾**。用于两个场景：
  #     1. 页面上的「检查分支」按钮（手动检查，只提示、不影响生成）；
  #     2. AI 建议分支后自动过滤，丢弃超纲/矛盾的建议。
  #
  # 隐性知识：
  #   1. 判定必须严格区分三种：ok / stricter（超纲）/ contradiction（矛盾）。
  #      判定基准只有一个：**主线描述**。主线没写的规则、阈值、失败处理、终止条件，
  #      分支不得自行添加（实测过：主线只在 show version 步声明 %Error 规则，
  #      分支却把它用到 show install active 上，属于超纲）。
  #   2. "规则跟着它所在的命令走"：把某一步声明的规则挪到别的命令上算超纲，
  #      不能算 ok。
  #   3. 分支结论与主线结论相反/互斥才算矛盾；只是更具体、报文不同不算。
  module BranchConsistency
    # 判定取值
    VERDICTS = %w[ok stricter contradiction].freeze

    def self.build(mainline_description, branches = [])
      branch_lines = Array(branches).each_with_index.map do |branch, index|
        name = branch[:name] || branch['name']
        desc = branch[:description] || branch['description']
        "#{index}. #{name}：\n#{desc}"
      end.join("\n\n")

      <<~PROMPT
        主线需求描述（判定基准）：
        ```
        #{Prompts.escape_interpolation(mainline_description)}
        ```

        待检查的分支场景（编号即 index）：
        #{Prompts.escape_interpolation(branch_lines)}

        请逐条比较每个分支与主线，判断该分支是否**超出主线要求**或**与主线矛盾**。

        判定口径（必须严格区分）：
        - `ok`：分支只是换了一组报文/数值去触发主线**已声明**的规则，处理与结论都与主线一致；
        - `stricter`（超纲）：分支新增了主线**未声明**的判定、阈值、失败处理或终止条件；
          或把主线某一步声明的规则挪到了别的命令上（规则应跟着它所在的命令走）；
          或对主线已声明为"可接受/通过"的情况提出了更严的要求。
        - `contradiction`（矛盾）：分支的预期结论或处理与主线声明相反、互斥，
          例如主线要求"继续后续步骤"而分支要求"结束整个流程"。

        要求：
        1. 每条分支输出一条结果，`index` 与上面的编号一致，`name` 原样返回；
        2. `reason` 用一两句话说清判定依据；`offending` 列出具体的越界/矛盾点（没有则为空数组）；
        3. 判断以主线描述为准：主线没写的规则，分支不得自行添加；
        4. 只做范围与一致性判断，不评价脚本实现，也不要改写分支内容。

        只输出 JSON，包含在 ```json 代码块中，格式如下：
        ```json
        {
          "results": [
            { "index": 0, "name": "分支1", "verdict": "ok", "reason": "…", "offending": [] }
          ]
        }
        ```
      PROMPT
    end

    def self.system_prompt
      <<~PROMPT
        角色：
          你是网络设备自动化测试的"需求一致性审查员"，负责判断"分支测试场景"是否
          超出或违背了"主线需求"的范围。

        硬性规则：
          1. 判定只有三种：`ok` / `stricter`（超纲）/ `contradiction`（矛盾）。
          2. 主线未声明的规则、阈值、失败处理、终止条件，分支不得引入；引入即 `stricter`。
          3. 规则跟着它所在的命令走：把某一步的规则挪到别的命令上算 `stricter`。
          4. 分支预期结论与主线结论相反或互斥算 `contradiction`；只是更具体不算。
          5. 每条分支输出一条结果，`index` 与输入顺序一致，不遗漏、不合并。
          6. 只输出 JSON，不输出多余解释。
      PROMPT
    end
  end
end

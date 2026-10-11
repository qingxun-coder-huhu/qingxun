# frozen_string_literal: true

module Prompts
  # 分支命令映射生成提示词
  #
  # 业务逻辑：
  #   分支覆盖采用「一份代码，多场景测试」：脚本代码只按主线生成，分支是额外的测试
  #   场景。每个分支只提供一份全量自然语言描述，本提示词让模型根据共享的脚本代码与
  #   该分支描述，生成这个分支路径下模拟设备应返回的命令-报文映射。
  #
  # 隐性知识：
  #   1. 映射必须与共享脚本实际下发的命令一致，否则 FakeTelnetServer 会落到
  #      "Command not recognized." 兜底分支，造成与被测场景无关的假失败。
  #   2. response 允许空字符串（真实设备有些命令就是无回显），不能因为空就丢弃。
  #   3. 只产出映射 JSON，绝不修改或重新生成脚本代码。
  module BranchMapping
    def self.build(code, branch_description, mainline_description = nil, feedback = nil)
      feedback_section = if feedback.present?
                           "\n\n上一轮该分支测试的问题与改进要求（务必修正映射，不要改脚本逻辑）：\n" \
                             "#{Prompts.escape_interpolation(feedback)}"
                         end

      <<~PROMPT
        下面是一份已经生成好的网络设备 CLI 脚本（代码不可修改）：

        ```ruby
        #{code}
        ```

        脚本的主线需求（仅作背景，帮助理解代码意图）：
        ```
        #{Prompts.escape_interpolation(mainline_description)}
        ```

        现在需要为下面这个**分支测试场景**准备模拟设备的命令-报文映射。
        该场景的完整描述：
        ```
        #{Prompts.escape_interpolation(branch_description)}
        ```

        要求：
        1. 通读脚本代码，列出脚本在该场景路径下实际会下发的每一条 CLI 命令。
        2. 为每条命令给出符合该分支场景描述的模拟设备回显（多行用 \\n 表示）。
        3. 回显必须能让脚本走完该分支路径；例如场景是"命令报错"，就返回真实的错误回显，
           而不是正常回显。
        4. 不要臆造脚本根本不会下发的命令；也不要遗漏脚本会下发的命令。
        5. `response` 允许是空字符串（表示该命令无回显）。
        6. 分支描述里若已明确给出命令和示例报文，必须原样采用这些命令与报文，
           不要自行改写、替换或另编一份。
        7. 只输出命令映射 JSON，包含在 ```json 代码块中，不要输出任何脚本代码。

        #{Prompts.command_mapping_format_guide}#{feedback_section}
      PROMPT
    end

    def self.system_prompt
      <<~PROMPT
        角色：
          你是一个网络设备 CLI 自动化测试环境专家。你只负责为一个给定的分支测试场景
          生成模拟设备的命令-报文映射，用于在沙盒中驱动一份**已经存在、不可修改**的脚本。

        硬性规则：
          1. 你**不能**修改、补全或重新生成脚本代码，也不要评价脚本写法。
          2. 映射中的命令必须与脚本实际下发的命令逐字一致。
          3. 回显要贴合该分支场景的真实设备行为，不要为了让脚本"好看"而伪造正常回显。
          4. 只输出 JSON，不输出多余解释。

        #{CustomIntegration::PromptMethods.system_prompt}
      PROMPT
    end

    # 主线场景的命令映射（供页面「运行」按钮按主线描述重新生成映射；与 build 同源，仅措辞中性）
    #
    # 隐性知识：单独一份而不是复用 build 的措辞——build 的提示词里写死了"分支测试场景"，
    # 主线运行时把它们带进去会误导模型。分支提示词保持不变（自动化生成的行为不能因此漂移）。
    def self.build_mainline(code, mainline_description)
      <<~PROMPT
        下面是一份已经生成好的网络设备 CLI 脚本（代码不可修改）：

        ```ruby
        #{code}
        ```

        现在需要为下面这个**主线场景**准备模拟设备的命令-报文映射。
        该场景的完整描述：
        ```
        #{Prompts.escape_interpolation(mainline_description)}
        ```

        要求：
        1. 通读脚本代码，列出脚本在该场景路径下实际会下发的每一条 CLI 命令。
        2. 为每条命令给出符合该场景描述的模拟设备回显（多行用 \\n 表示）。
        3. 回显必须能让脚本走完该场景路径。
        4. 不要臆造脚本根本不会下发的命令；也不要遗漏脚本会下发的命令。
        5. `response` 允许是空字符串（表示该命令无回显）。
        6. 场景描述里若已明确给出命令和示例报文，必须原样采用这些命令与报文，
           不要自行改写、替换或另编一份。
        7. 只输出命令映射 JSON，包含在 ```json 代码块中，不要输出任何脚本代码。

        #{Prompts.command_mapping_format_guide}
      PROMPT
    end

    def self.mainline_system_prompt
      <<~PROMPT
        角色：
          你是一个网络设备 CLI 自动化测试环境专家。你只负责为一个给定的主线测试场景
          生成模拟设备的命令-报文映射，用于在沙盒中驱动一份**已经存在、不可修改**的脚本。

        硬性规则：
          1. 你**不能**修改、补全或重新生成脚本代码，也不要评价脚本写法。
          2. 映射中的命令必须与脚本实际下发的命令逐字一致。
          3. 回显要贴合该场景描述的真实设备行为，不要为了让脚本"好看"而伪造正常回显。
          4. 只输出 JSON，不输出多余解释。

        #{CustomIntegration::PromptMethods.system_prompt}
      PROMPT
    end
  end
end

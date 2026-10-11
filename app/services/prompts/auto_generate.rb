# frozen_string_literal: true

module Prompts
  module AutoGenerate
    def self.final_suggestion(description, history_text, max_attempts)
      <<~PROMPT
        你是一个网络设备 CLI 自动化专家。用户尝试自动生成脚本，但经过 #{max_attempts} 次尝试后仍然失败。

        ## 用户原始需求
        #{description}

        ## 尝试历史
        #{history_text}

        请分析上述失败原因，并给出具体的下一步建议。建议应该：
        1. 明确指出问题可能出在哪里
        2. 提供用户可以尝试的具体操作
        3. 如果是需求描述不够清晰，给出更好的描述示例
        4. 如果是系统限制，说明可能的替代方案

        请用简洁、友好的中文给出建议（2-3句话即可）。
      PROMPT
    end

    def self.final_suggestion_system_prompt
      '你是一个网络设备 CLI 自动化专家，擅长分析问题并给出实用的建议。'
    end
  end
end

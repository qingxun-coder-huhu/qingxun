# frozen_string_literal: true

# 用户自定义集成（单例）
#
# 存储用户定义的函数列表和 Mock 响应
#
class CustomIntegration < ApplicationRecord
  belongs_to :user

  # 每个用户只有一个自定义集成
  validates :user_id, uniqueness: true

  # functions 结构示例：
  # [
  #   {
  #     "name" => "send_alarm",
  #     "param_example" => "{\"cpu\": 90}",
  #     "mock_response" => "{\"success\": true}"
  #   }
  # ]

  # 获取用户的集成，不存在则创建
  def self.for_user(user)
    find_or_create_by(user: user)
  end

  # 版本哈希（以生成代码为准，取前 8 位）
  def version_hash
    return nil if generated_code.blank?

    Digest::SHA256.hexdigest(generated_code)[0, 8]
  end

  # 记录一次编辑历史快照（保留最近 30 条）。
  #
  # 隐性知识：快照存**函数定义与生成代码**本身，而不是对"当前状态"的引用；
  # 这样历史条目不随当前记录变化，将来也便于做回滚。
  def record_history!(notes: nil)
    return if generated_code.blank?

    snapshot = {
      'version_hash' => version_hash,
      'functions' => functions,
      'generated_code' => generated_code,
      'notes' => notes.to_s,
      'created_at' => Time.current.iso8601
    }
    self.history = ([snapshot] + Array(history)).first(30)
  end

  # 获取所有函数名
  def function_names
    functions.pluck("name")
  end

  # 获取函数的 Mock 响应
  def mock_response_for(function_name)
    func = functions.find { |f| f["name"] == function_name.to_s }
    return { "success" => true } unless func

    JSON.parse(func["mock_response"]) rescue { "success" => true }
  end

  # 生成用于提示词的上下文信息
  def to_prompt_context
    return "无自定义函数" if functions.empty?

    lines = []
    functions.each do |func|
      name = func["name"]
      param_example = func["param_example"]
      mock_response = func["mock_response"]

      lines << "- 函数名: #{name}"
      lines << "  参数示例: #{param_example}"
      lines << "  返回示例: #{mock_response}"
    end

    lines.join("\n")
  end

  # 提示词模块方法
  class PromptMethods
    def self.system_prompt
      <<~PROMPT
        你可以使用用户自定义的集成函数。

        重要：要使用自定义集成，必须在脚本类中添加以下声明：
        ```
        class YourScriptName < Qingxun::DeviceScript
          uses_integration :custom
          # ... 其他代码
        end
        ```

        使用方式：声明后，在脚本中通过 custom.函数名(params) 调用。
        - params 参数必须符合用户定义的参数示例格式
        - 调用后返回用户预设的响应数据
      PROMPT
    end

    def self.build_prompt(user_custom_integration)
      return "" if user_custom_integration.blank?

      context = user_custom_integration.to_prompt_context
      <<~PROMPT
        用户已定义以下自定义函数：

        #{context}

        重要：要使用自定义集成，必须在脚本类中添加以下声明：
        ```
        class YourScriptName < Qingxun::DeviceScript
          uses_integration :custom
          # ... 其他代码
        end
        ```

        调用方式：声明后，在脚本中通过 custom.函数名({ 参数 }) 调用。

        示例：
        result = custom.send_alarm({ cpu: 90 })
      PROMPT
    end
  end
end

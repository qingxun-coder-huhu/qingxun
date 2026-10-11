# frozen_string_literal: true

require_relative 'prompts'
require_relative 'prompts/branch_mapping'
require_relative 'command_mapping_parser'
require_relative 'llm_request_service'

# BranchMappingGenerationService 为单个测试场景生成命令-报文映射。
#
# 业务逻辑：
#   场景覆盖是「一份代码 + 多个测试场景」。本服务不改脚本代码，只根据共享代码与
#   该场景的全量描述，产出该路径下模拟设备应有的命令-报文映射，供 DebugSession 使用。
#   默认 scenario_kind: :branch（分支场景，自动化生成走这条）；页面「运行」按钮也可用
#   scenario_kind: :main 为主线按描述重新生成映射——两者只是提示词措辞不同，都不碰代码。
#
# 隐性知识：
#   1. 失败不抛异常：映射生成失败只应降级为该场景失败，不能中断整个流程。
#   2. 但 LlmApiKey::MissingApiKeyError 刻意继承自 Exception，裸 rescue 不会吞掉它，
#      这样缺少 Key 时仍能由控制器统一翻译成明确提示。
#   3. 分支提示词（Prompts::BranchMapping.build）保持不变：自动化生成的模型行为不能因
#      这个新入口而漂移；主线另用中性措辞的 build_mainline。
class BranchMappingGenerationService
  def initialize(code, branch_description, mainline_description: nil, feedback: nil, user: nil, scenario_kind: :branch)
    @code = code.to_s
    @branch_description = branch_description.to_s.strip
    @mainline_description = mainline_description.to_s
    @feedback = feedback
    @user = user
    @scenario_kind = scenario_kind.to_sym == :main ? :main : :branch
  end

  # 返回 { command_mapping: [...], error: nil|String }
  def call
    if @code.strip.empty?
      error = @scenario_kind == :main ? '脚本代码为空，无法生成命令映射' : '脚本代码为空，无法生成分支映射'
      return { command_mapping: [], error: error }
    end
    if @branch_description.empty?
      return { command_mapping: [], error: @scenario_kind == :main ? '主线描述为空' : '分支描述为空' }
    end

    prompt = if @scenario_kind == :main
               Prompts::BranchMapping.build_mainline(@code, @branch_description)
             else
               Prompts::BranchMapping.build(@code, @branch_description, @mainline_description, @feedback)
             end
    response = LlmRequestService.call(
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: prompt }
      ],
      service_name: 'BranchMappingGenerationService',
      step_name: @scenario_kind == :main ? 'generate_mainline' : 'generate'
    )

    content = response.dig('choices', 0, 'message', 'content').to_s
    raise '命令映射响应为空' if content.strip.empty?

    json_match = content.match(/```json\s*(.*?)```/m)
    mapping_content = json_match ? json_match[1] : content
    { command_mapping: CommandMappingParser.parse(mapping_content), error: nil }
  rescue => e
    label = @scenario_kind == :main ? '主线' : '分支'
    Rails.logger.warn("[BranchMappingGenerationService] 生成#{label}映射失败: #{e.class}: #{e.message}")
    { command_mapping: [], error: e.message }
  end

  private

  def system_prompt
    base = if @scenario_kind == :main
             Prompts::BranchMapping.mainline_system_prompt
           else
             Prompts::BranchMapping.system_prompt
           end
    if @user.present?
      custom_integration = @user.custom_integration
      if custom_integration.present? && custom_integration.functions.present?
        base += "\n\n#{CustomIntegration::PromptMethods.build_prompt(custom_integration)}"
      end
    end
    base
  end
end

# frozen_string_literal: true

require 'json'
require_relative 'description_draft_payload'
require_relative 'llm_request_service'
require_relative 'prompts'
require_relative 'prompts/description_improvement'

# 按「客户端真实执行日志 + 用户要求」改进脚本的主线描述。
#
# 业务逻辑：
#   用户在本机跑完一次执行后，把日志与自己的要求转交到云端（见 ScriptLogHandoff），
#   在生成页点「确定开始修改」时调到这里：模型拿到当前主线描述、用户要求、真实日志与
#   检查点结论，输出**整份改进后的描述**（不是补丁）。页面预览后由用户决定是否应用。
#
# 与 ScriptRequirementDraftService 的关系：
#   输出契约完全一致（description / open_questions / notes），规范化逻辑共用
#   DescriptionDraftPayload。区别只在提示词：那个从零整理，这个在既有描述上改。
#
# 隐性知识：
#   1. **不静默降级**：失败必须把错误回传前端可见（用户点了按钮就得知道为什么没成）。
#      不沿用 TaskRequirementEnhancementService 那种被自己的 rescue 吞掉的写法。
#   2. 日志长度上限是体验护栏（40_000 字符）：超限直接失败并提示删减，**不静默截断** ——
#      截断会丢掉判定要用的回显，改出来的描述比不改更糟。
#   3. 日志可以为空（用户把敏感内容删光后只想按要求改描述），此时提示词会退化成
#      "只依据要求与当前描述改进"；用户要求本身不能为空，否则就是让模型自由发挥。
#   4. 本服务**不保存任何东西**：日志与描述进的是 LLM 请求，出的是内存里的字符串。
class ScriptDescriptionImprovementService
  # 与手工日志路径保持一致的上限（客户端也按它提示）
  MAX_LOG_LENGTH = 40_000
  MAX_CHECKPOINTS = 200

  Payload = DescriptionDraftPayload

  def initialize(description:, requirement:, log:, checkpoints: [], error: nil, user: nil)
    @description = description.to_s
    @requirement = requirement.to_s.strip
    @log = log.to_s.strip
    @checkpoints = checkpoints.is_a?(Array) ? checkpoints : []
    @error = error.to_s.strip
    @user = user
  end

  # 返回 { success:, description:, open_questions: [], notes: [], error: }
  def call
    validation_error = validate_inputs
    return failure(validation_error) if validation_error

    data = Payload.parse_json(request_improvement)
    return failure('模型未返回可用的描述，请重试或缩短日志') if data.nil?

    description = data['description'].to_s.strip
    return failure('模型未返回描述内容，请重试') if description.empty?

    questions = Payload.normalize_questions(data['open_questions'])
    {
      success: true,
      description: Payload.ensure_placeholders(description, questions),
      open_questions: questions,
      notes: Payload.normalize_notes(data['notes']),
      error: nil
    }
  rescue LlmRequestService::MaxTokensReachedError
    failure('日志过长导致模型输出被截断，请删减无关内容后重试')
  rescue => e
    # 只记长度与错误类型：日志与描述是客户内容，不进平台日志
    Rails.logger.warn("[ScriptDescriptionImprovementService] 改进描述失败: #{e.class}: #{e.message} " \
                      "(log_length=#{@log.length}, description_length=#{@description.length})")
    failure(e.message)
  end

  private

  def validate_inputs
    return '请先填写你的要求' if @requirement.empty?

    if @log.length > MAX_LOG_LENGTH
      return "日志超过 #{MAX_LOG_LENGTH} 字符上限（当前 #{@log.length} 字符），请删减无关内容后重试"
    end

    nil
  end

  def request_improvement
    response = LlmRequestService.call(
      messages: [
        { role: 'system', content: system_prompt },
        {
          role: 'user',
          content: Prompts::DescriptionImprovement.build(
            description: @description,
            requirement: @requirement,
            log: @log,
            checkpoints_text: checkpoints_text,
            error: @error
          )
        }
      ],
      service_name: 'ScriptDescriptionImprovementService',
      step_name: 'improve'
    )
    response.dig('choices', 0, 'message', 'content').to_s
  end

  # 检查点结论按"一行一条"喂给模型：与界面上的展示一致，模型也更容易对齐描述里的判据
  def checkpoints_text
    @checkpoints.first(MAX_CHECKPOINTS).filter_map do |checkpoint|
      next unless checkpoint.is_a?(Hash) || checkpoint.respond_to?(:to_unsafe_h)

      item = checkpoint.respond_to?(:to_unsafe_h) ? checkpoint.to_unsafe_h : checkpoint
      name = item['name'].to_s.strip
      next if name.empty?

      mark = item['passed'] == true ? '✓' : (item['passed'] == false ? '✗' : '?')
      line = "#{mark} #{name}"
      value = item['value'].to_s.strip
      line += "（实际：#{value}）" unless value.empty?
      reason = item['reason'].to_s.strip
      line += " — #{reason}" if item['passed'] == false && !reason.empty?
      line
    end.join("\n")
  end

  def failure(message)
    { success: false, description: nil, open_questions: [], notes: [], error: message }
  end

  def system_prompt
    base = Prompts::DescriptionImprovement.system_prompt
    if @user.present?
      custom_integration = @user.custom_integration
      if custom_integration.present? && custom_integration.functions.present?
        base += "\n\n#{CustomIntegration::PromptMethods.build_prompt(custom_integration)}"
      end
    end
    base
  end
end

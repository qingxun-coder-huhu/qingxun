# frozen_string_literal: true

require 'json'
require_relative 'prompts'
require_relative 'prompts/requirement_draft'
require_relative 'description_draft_payload'
require_relative 'llm_request_service'

# ScriptRequirementDraftService 把「用户目标 + 手工操作日志」整理成需求描述框架。
#
# 业务逻辑：
#   用户手工操作设备时留下的终端日志，天然包含逐字命令与真实回显——这正是一份需求描述里
#   最难拿到、也最决定成败的部分。本服务让模型把日志与目标整理成符合平台规范的框架
#   （命令 / 回显 / 处理逻辑 / 预期 / 字段来源 / 分层 / 分支），日志里没有的判据一律留成
#   带候选的待确认占位，交给用户点选或自己填写。
#
# 隐性知识：
#   1. **不静默降级**：失败必须把错误回传前端可见。任务侧那个
#      TaskRequirementEnhancementService 引用了一个不存在的常量（Prompts::TaskCreation::
#      RequirementEnhancement），又被自己的 rescue 吞掉，表现成"点了没反应"；本服务不沿用
#      那种写法——rescue 只兜底，错误照实返回。
#   2. 日志长度上限是**体验护栏**，不是模型限制；超限直接失败并提示截取，不做静默截断——
#      截断会丢掉回显，反而让生成的命令映射出错。
#   3. 脱敏由用户负责（页面上给出提示）：日志里可能含密码、IP、SNMP 社区串。
#      服务端不做自动脱敏，也不把日志写进任何日志文件。
class ScriptRequirementDraftService
  # 手工操作日志的长度上限（字符）
  MAX_LOG_LENGTH = 40_000

  MAX_OPTIONS = Prompts::RequirementDraft::MAX_OPTIONS
  # 载荷规范化（解析 JSON、待确认项、占位符兜底、notes）与"按真实日志改进主线描述"共用一份，
  # 见 DescriptionDraftPayload —— 占位符契约是平台级约定，两处各写一份必然分叉。
  Payload = DescriptionDraftPayload

  def initialize(goal, log, user: nil)
    @goal = goal.to_s.strip
    @log = log.to_s.strip
    @user = user
  end

  # 返回 { success:, description:, open_questions: [{ id:, question:, options: [] }], notes: [], error: }
  def call
    validation_error = validate_inputs
    return failure(validation_error) if validation_error

    content = request_draft
    data = Payload.parse_json(content)
    return failure('模型未返回可用的需求框架，请重试或缩短日志') if data.nil?

    description = data['description'].to_s.strip
    return failure('模型未返回需求描述内容，请重试') if description.empty?

    questions = Payload.normalize_questions(data['open_questions'])
    {
      success: true,
      description: Payload.ensure_placeholders(description, questions),
      open_questions: questions,
      notes: Payload.normalize_notes(data['notes']),
      error: nil
    }
  rescue LlmRequestService::MaxTokensReachedError
    failure('日志过长导致模型输出被截断，请截取关键片段后重试')
  rescue => e
    Rails.logger.warn("[ScriptRequirementDraftService] 生成需求框架失败: #{e.class}: #{e.message}")
    failure(e.message)
  end

  private

  def validate_inputs
    return '请先填写目标' if @goal.empty?
    return '请粘贴手工操作日志' if @log.empty?

    if @log.length > MAX_LOG_LENGTH
      return "日志超过 #{MAX_LOG_LENGTH} 字符上限（当前 #{@log.length} 字符），请截取关键片段后重试"
    end

    nil
  end

  def request_draft
    response = LlmRequestService.call(
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: Prompts::RequirementDraft.build(@goal, @log) }
      ],
      service_name: 'ScriptRequirementDraftService',
      step_name: 'draft'
    )
    response.dig('choices', 0, 'message', 'content').to_s
  end

  # 从模型回复里抓 JSON 对象、待确认项规范化、占位符兜底与 notes 都搬到
  # DescriptionDraftPayload（与"按真实日志改进主线描述"共用一份，见类顶部说明）。
  def failure(message)
    { success: false, description: nil, open_questions: [], notes: [], error: message }
  end

  def system_prompt
    base = Prompts::RequirementDraft.system_prompt
    if @user.present?
      custom_integration = @user.custom_integration
      if custom_integration.present? && custom_integration.functions.present?
        base += "\n\n#{CustomIntegration::PromptMethods.build_prompt(custom_integration)}"
      end
    end
    base
  end
end

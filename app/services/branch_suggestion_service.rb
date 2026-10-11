# frozen_string_literal: true

require_relative 'prompts'
require_relative 'prompts/branch_suggestion'
require_relative 'branch_consistency_service'
require_relative 'llm_request_service'

# BranchSuggestionService 根据主线描述与已有分支，给出建议分支场景。
#
# 业务逻辑：
#   用户点击「AI建议分支」时调用，返回 [{ name:, description: }]，由用户勾选是否采纳。
#   本服务只产出测试场景建议，不改动任何已有分支。
#   传 custom_requirement 时走「自定义场景」：由用户指定一个/多个场景，模型据此生成
#   1~N 条（条数随输入而定，不凑数），而不是默认那种固定 3 条。
#
# 隐性知识：
#   1. 解析失败或调用失败都返回 success:false + error，不向上抛异常——建议功能失败
#      不该影响用户手动填写分支。
#   2. 即使模型多给了建议，也只取前 limit 条（默认 MAX_SUGGESTIONS，自定义时 MAX_CUSTOM_SUGGESTIONS）。
#   3. 自定义场景同样要过一致性校验：用户点名要的场景也不能超出主线已声明的规则，
#      超纲的照样丢弃并给出原因（让用户知道"要覆盖它得先写进主线"）。
class BranchSuggestionService
  MAX_SUGGESTIONS = Prompts::BranchSuggestion::MAX_SUGGESTIONS
  MAX_CUSTOM_SUGGESTIONS = Prompts::BranchSuggestion::MAX_CUSTOM_SUGGESTIONS

  def initialize(mainline_description, existing_branches: [], avoid_branches: [], custom_requirement: nil, user: nil)
    @mainline_description = mainline_description.to_s.strip
    @existing_branches = normalize_branches(existing_branches)
    @avoid_branches = normalize_branches(avoid_branches)
    @custom_requirement = custom_requirement.to_s.strip
    @user = user
  end

  # 返回 { success: Boolean, branches: [{ name:, description: }],
  #        dropped: [{ name:, verdict:, reason: }], consistency_checked: Boolean, error: String|nil }
  def call
    return { success: false, branches: [], dropped: [], consistency_checked: false, error: '主线描述不能为空' } if @mainline_description.empty?

    custom = @custom_requirement.present?
    prompt = if custom
               Prompts::BranchSuggestion.build_custom(@mainline_description, @custom_requirement,
                                                      @existing_branches, @avoid_branches)
             else
               Prompts::BranchSuggestion.build(@mainline_description, @existing_branches, @avoid_branches)
             end
    limit = custom ? MAX_CUSTOM_SUGGESTIONS : MAX_SUGGESTIONS

    response = LlmRequestService.call(
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: prompt }
      ],
      service_name: 'BranchSuggestionService',
      step_name: custom ? 'suggest_custom' : 'suggest'
    )

    content = response.dig('choices', 0, 'message', 'content').to_s
    json_match = content.match(/\{.*\}/m)
    raise '未找到建议结果' unless json_match

    data = JSON.parse(json_match[0])
    branches = Array(data['branches'])
               .map { |b| { name: b['name'].to_s.strip, description: b['description'].to_s.strip } }
               .reject { |b| b[:description].empty? }
               .first(limit)

    if branches.empty?
      error = custom ? '未能按您的描述生成有效分支，请把场景写得更具体些' : '模型未给出有效建议'
      return { success: false, branches: [], dropped: [], consistency_checked: false, error: error }
    end

    filter_by_consistency(branches)
  rescue => e
    Rails.logger.warn("[BranchSuggestionService] 生成建议分支失败: #{e.class}: #{e.message}")
    { success: false, branches: [], dropped: [], consistency_checked: false, error: e.message }
  end

  private

  # 用 BranchConsistencyService 过滤超纲/矛盾的建议。
  # 校验服务本身失败时 fail-open：保留建议并标记 consistency_checked=false，
  # 避免因校验故障让用户拿不到任何建议。
  def filter_by_consistency(branches)
    check = BranchConsistencyService.new(@mainline_description, branches).call
    unless check[:success]
      return { success: true, branches: branches, dropped: [], consistency_checked: false, error: nil }
    end

    kept = []
    dropped = []
    check[:results].each do |result|
      branch = branches[result[:index]]
      next unless branch

      if result[:verdict] == 'ok'
        kept << branch
      else
        dropped << { name: branch[:name], verdict: result[:verdict], reason: result[:reason] }
      end
    end

    if kept.empty?
      return {
        success: false, branches: [], dropped: dropped, consistency_checked: true,
        error: '建议的分支都超出主线要求或与主线矛盾，请把相应规则写进主线描述后重试'
      }
    end

    { success: true, branches: kept, dropped: dropped, consistency_checked: true, error: nil }
  end

  def normalize_branches(branches)
    Array(branches).map do |b|
      if b.respond_to?(:[])
        { name: (b[:name] || b['name']).to_s.strip, description: (b[:description] || b['description']).to_s.strip }
      end
    end.compact.reject { |b| b[:description].empty? }
  end

  def system_prompt
    base = if @custom_requirement.present?
             Prompts::BranchSuggestion.custom_system_prompt
           else
             Prompts::BranchSuggestion.system_prompt
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

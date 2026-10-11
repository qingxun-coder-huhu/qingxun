# frozen_string_literal: true

require_relative 'prompts'
require_relative 'prompts/branch_consistency'
require_relative 'llm_request_service'

# BranchConsistencyService 检查分支是否超出主线要求或与主线矛盾。
#
# 业务逻辑：
#   输入主线描述与各分支描述，逐条给出判定（ok / stricter / contradiction）与原因。
#   用于页面「检查分支」按钮（只提示）与 AI 建议分支的自动过滤。
#
# 隐性知识：
#   1. 结果必须与输入分支一一对齐：模型漏项时补 verdict=unknown，避免前后端索引错位。
#   2. 解析失败/调用失败降级为 success:false + error，不抛异常（建议功能可据此 fail-open）。
#   3. LlmApiKey::MissingApiKeyError 刻意继承自 Exception，裸 rescue 不会吞掉它，
#      缺少 Key 时仍由控制器统一翻译成明确提示。
class BranchConsistencyService
  # 除三种正常判定外，模型未给出/无法识别时记为 unknown（前端按"无法判定"展示）
  UNKNOWN = 'unknown'

  def initialize(mainline_description, branches)
    @mainline_description = mainline_description.to_s.strip
    @branches = normalize_branches(branches)
  end

  # 返回 { success:, results: [{index:, name:, verdict:, reason:, offending: []}], has_issues:, error: }
  def call
    if @mainline_description.empty?
      return { success: false, results: [], has_issues: false, error: '主线描述不能为空' }
    end
    return { success: true, results: [], has_issues: false, error: nil } if @branches.empty?

    prompt = Prompts::BranchConsistency.build(@mainline_description, @branches)
    response = LlmRequestService.call(
      messages: [
        { role: 'system', content: Prompts::BranchConsistency.system_prompt },
        { role: 'user', content: prompt }
      ],
      service_name: 'BranchConsistencyService',
      step_name: 'check'
    )

    content = response.dig('choices', 0, 'message', 'content').to_s
    json_match = content.match(/\{.*\}/m)
    raise '未找到检查结果' unless json_match

    data = JSON.parse(json_match[0])
    results = normalize_results(data['results'])

    { success: true, results: results, has_issues: results.any? { |r| r[:verdict] != 'ok' }, error: nil }
  rescue => e
    Rails.logger.warn("[BranchConsistencyService] 分支一致性检查失败: #{e.class}: #{e.message}")
    { success: false, results: [], has_issues: false, error: e.message }
  end

  private

  # 兼容 symbol/string 键，丢弃空描述
  def normalize_branches(branches)
    Array(branches).map do |branch|
      next unless branch.respond_to?(:[])

      {
        name: (branch[:name] || branch['name']).to_s.strip,
        description: (branch[:description] || branch['description']).to_s.strip
      }
    end.compact.reject { |branch| branch[:description].empty? }
  end

  # 与输入分支对齐：默认 unknown，按 index 覆盖；name 以输入为准
  def normalize_results(raw)
    results = @branches.each_with_index.map do |branch, index|
      {
        index: index,
        name: branch[:name],
        verdict: UNKNOWN,
        reason: '模型未给出该分支的判定',
        offending: []
      }
    end

    Array(raw).each_with_index do |item, position|
      next unless item.is_a?(Hash)

      target = index_for(item, position)
      next if target.nil?

      results[target] = {
        index: target,
        name: results[target][:name],
        verdict: normalize_verdict(item['verdict']),
        reason: item['reason'].to_s.strip,
        offending: Array(item['offending']).map { |o| o.to_s.strip }.reject(&:empty?)
      }
    end

    results
  end

  def index_for(item, position)
    raw = item['index']
    index = raw.is_a?(Integer) ? raw : raw.to_s.strip.to_i
    index = position unless raw.is_a?(Integer) || raw.to_s.strip.match?(/\A\d+\z/)
    index.between?(0, @branches.size - 1) ? index : nil
  end

  def normalize_verdict(raw)
    verdict = raw.to_s.strip.downcase
    return 'stricter' if verdict == 'strict'
    return verdict if Prompts::BranchConsistency::VERDICTS.include?(verdict)

    UNKNOWN
  end
end

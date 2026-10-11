# frozen_string_literal: true

require 'httparty'
require 'json'
require_relative 'llm_request_service'
require_relative 'prompts'

# ScriptEvaluationService 负责评估生成的脚本测试结果是否符合用户需求描述的预期。
#
# 业务逻辑：
#   - 接收原始需求描述、生成的脚本代码、命令映射、测试执行结果。
#   - 构建评估提示词，调用 DeepSeek API 进行智能评估。
#   - 判断测试结果是否满足需求描述的预期。
#   - 如果不满足，生成改进建议供下次生成参考。
#
# 隐性知识：
#   - 评估需要理解网络设备 CLI 操作的语义，判断返回值是否合理。
#   - 测试日志中的错误可能是脚本逻辑问题，也可能是模拟设备响应不匹配。
#   - 评估结果需要给出明确的通过/不通过判断，以及改进方向。
#
class ScriptEvaluationService
  # 日志截断阈值。
  #
  # 隐性知识：设备报文动辄上万字符，而评估 prompt 里同时还有代码与命令映射。
  # 不截断时 prompt 会到几十 KB，既费 token 又容易让模型丢掉关键细节。
  # 策略有两层：单行超长则截断该行；总条数超限则保留前 N 条并追加一条截断提示。
  # 条数上限取 40：脚本每次 cli 调用现在会各产生一条"下发命令/收到报文"，
  # 上限过小会把脚本自身的 log_info（关键中间结果）挤出 prompt。
  MAX_LOG_ENTRIES = 40
  MAX_LOG_LINE_LENGTH = 2000

  # 初始化评估服务。
  # 参数：
  #   description: 用户原始需求描述
  #   code: 生成的 Ruby 脚本代码
  #   command_mapping: 命令映射数组 [{ command: '...', response: '...' }]
  #   test_result: 测试执行结果 { success: Boolean, result: Object, logs: Array, error: String }
  def initialize(description, code, command_mapping, test_result)
    @description = description.to_s.strip
    @code = code.to_s.strip
    @command_mapping = command_mapping || []
    @test_result = test_result || {}
  end

  # 执行评估过程。
  # 返回哈希 {
  #   passed: Boolean,           # 是否通过评估（所有需求条目都通过才为 true）
  #   evaluation: String,        # 评估分析内容
  #   suggestions: Array<String>, # 改进建议列表
  #   issues: Array<String>,     # 发现的问题列表
  #   items: Array<Hash>,        # 逐条评估结果（需求条目 → 证据 → 通过与否 → 归因）
  #   env_mismatches: Array<String> # 测试环境/映射与真实设备不一致之处
  # }
  def call
    prompt = Prompts::ScriptEvaluation.build(@description, @code, @command_mapping, sanitize_test_result)
    response = call_deepseek_api(prompt)
    parse_evaluation_response(response)
  rescue => e
    Rails.logger.error "评估服务失败: #{e.message}"
    {
      passed: false,
      evaluation: "评估过程发生错误: #{e.message}",
      suggestions: ["请检查脚本生成服务是否正常工作"],
      issues: ["评估服务异常"],
      items: [],
      env_mismatches: [],
      user_questions: [],
      mapping_suggestions: []
    }
  end

  private

  # 清理测试结果，避免包含不可序列化的内容，并对过长的日志做截断。
  #
  # 隐性知识：这里刻意**只用纯 Ruby** 判断空值（nil / empty?），不用 ActiveSupport 的
  # `present?` —— 本服务的单测跑在纯 Ruby 环境（不加载 Rails），核心扩展不一定可用，
  # 用 `.present?` 会让单测因 NoMethodError 而整片失败（实测踩过）。
  def sanitize_test_result
    result = {
      success: @test_result[:success],
      error: @test_result[:error]
    }

    result[:result] = @test_result[:result] unless blank_value?(@test_result[:result])

    unless blank_value?(@test_result[:logs])
      result[:logs] = truncate_logs(@test_result[:logs].map { |l| truncate_log_line(l.to_s) })
    end

    result[:backtrace] = @test_result[:backtrace].first(5) unless blank_value?(@test_result[:backtrace])

    result
  end

  def blank_value?(value)
    value.nil? || (value.respond_to?(:empty?) && value.empty?)
  end

  # 日志总条数超限：保留前 N 条，并追加一条明确的截断提示
  def truncate_logs(logs)
    return logs if logs.size <= MAX_LOG_ENTRIES

    logs.first(MAX_LOG_ENTRIES) +
      ["……（日志已截断，共 #{logs.size} 条，仅保留前 #{MAX_LOG_ENTRIES} 条）"]
  end

  # 单行超长（例如整段设备报文被塞进一条日志）：截断该行
  def truncate_log_line(line)
    return line if line.length <= MAX_LOG_LINE_LENGTH

    "#{line[0, MAX_LOG_LINE_LENGTH]}……（本行已截断，原长 #{line.length} 字符）"
  end

  # 调用 LLM API。
  def call_deepseek_api(prompt)
    LlmRequestService.call(
      messages: [
        { role: 'system', content: Prompts::ScriptEvaluation.system_prompt },
        { role: 'user', content: prompt }
      ],
      service_name: 'ScriptEvaluationService',
      step_name: 'evaluate'
    )
  end

  # 解析评估响应。
  def parse_evaluation_response(api_response)
    content = api_response.dig('choices', 0, 'message', 'content')
    raise 'API 响应未包含内容' if content.nil?

    # 清理函数：剥离代码块标记
    clean_content = lambda do |str|
      return '' if str.nil?
      str = str.to_s.strip
      # 剥离代码块标记（从开头和结尾）
      str = str.gsub(/\A```(?:json|ruby|text)?\s*/, '').gsub(/```\s*\z/, '')
      str.strip
    end

    # 尝试提取 JSON 代码块 - 支持多种格式
    json_content = nil
    
    # 格式 1: ```json ... ```
    json_match = content.match(/```json\s*(.*?)```/m)
    if json_match
      json_content = json_match[1].strip
    else
      # 格式 2: ``` ... ``` (无语言标记)
      json_match = content.match(/```\s*(.*?)```/m)
      if json_match
        json_content = json_match[1].strip
      else
        # 格式 3: 直接就是 JSON
        json_content = content.strip
      end
    end

    # 进一步清理 JSON 内容
    json_content = json_content.gsub(/\A```(?:json)?\s*/, '').gsub(/```\s*\z/, '').strip

    begin
      result = JSON.parse(json_content)
      items = normalize_items(result['items'])

      # passed 只由"本次需求描述拆出的条目"决定：全部条目通过才通过。
      #
      # 隐性知识（踩过坑）：不能直接信模型顶层的 passed。模型常在逐条给完全部通过后，
      # 又在正文里提到与本次需求无关的问题（例如共享脚本其他环节的硬编码），并把顶层
      # passed 写成 false，于是页面出现"需求条目全部通过，却判测试未通过"的自相矛盾结论。
      # 这里改为以条目为准：有条目时只看条目；没有条目时才回退到模型的顶层判定。
      passed =
        if items.any?
          items.all? { |it| it[:passed] != false }
        else
          result['passed'] == true
        end

      {
        passed: passed,
        evaluation: clean_content.call(result['evaluation']),
        suggestions: (result['suggestions'] || []).map { |s| clean_content.call(s) },
        issues: (result['issues'] || []).map { |s| clean_content.call(s) },
        items: items,
        env_mismatches: (result['env_mismatches'] || []).map { |s| clean_content.call(s) },
        user_questions: (result['user_questions'] || []).map { |q| clean_content.call(q) },
        mapping_suggestions: normalize_mapping_suggestions(result['mapping_suggestions'])
      }
    rescue JSON::ParserError => e
      Rails.logger.warn "评估响应 JSON 解析失败: #{e.message}"
      # 尝试从文本中推断结果
      passed = content.include?('"passed": true') || content.include?('"passed":true')
      {
        passed: passed,
        evaluation: clean_content.call(content),
        suggestions: [],
        issues: ["无法解析结构化评估结果"],
        items: [],
        env_mismatches: [],
        user_questions: [],
        mapping_suggestions: []
      }
    end
  end

  # 逐条评估结果的规范化。字段缺失时给出安全的默认值，
  # 保证下游（build_error_history / 前端）拿到的结构稳定。
  def normalize_items(raw)
    return [] unless raw.is_a?(Array)

    raw.filter_map do |item|
      next unless item.is_a?(Hash)

      {
        requirement: item['requirement'].to_s,
        checkpoint: item['checkpoint'],
        passed: item['passed'] == true,
        expected: item['expected'].to_s,
        observed: item['observed'].to_s,
        evidence: item['evidence'].to_s,
        attribution: (item['attribution'].to_s.empty? ? 'unknown' : item['attribution'].to_s),
        note: item['note'].to_s
      }
    end
  end

  # 命令映射补充建议的规范化。
  # 这些建议会被第二轮生成用来补齐测试环境的命令映射，因此 command 必须逐字保留。
  def normalize_mapping_suggestions(raw)
    return [] unless raw.is_a?(Array)

    raw.filter_map do |item|
      next unless item.is_a?(Hash)

      command = item['command'].to_s
      next if command.empty?

      {
        command: command,
        issue: item['issue'].to_s,
        suggested_response: item['suggested_response'].to_s,
        reason: item['reason'].to_s
      }
    end
  end
end

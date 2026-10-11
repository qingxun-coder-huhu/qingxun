# frozen_string_literal: true

require 'json'
require_relative 'prompts/requirement_draft'

# 「描述类」LLM 调用的返回载荷规范化。
#
# 业务逻辑：
#   两条路径都让模型返回同一形状的 JSON —— 手工日志整理出需求框架（ScriptRequirementDraftService）
#   与按真实日志改进主线描述（ScriptDescriptionImprovementService）：
#     { description, open_questions: [{id, question, options}], notes: [] }
#   而"待确认"的契约（占位符格式、每个问题最多几个候选、正文里必须有可回填的占位符）是
#   **平台级约定**：界面靠占位符做点选回填，模型漏写就会让用户点了候选却没地方填。
#   所以规范化只写一份，两个服务共用；约束仍由 Prompts::RequirementDraft 定义。
#
# 隐性知识：
#   1. 解析失败返回 nil，由调用方转成**可见错误**，不要在这里抛异常（上层会变成 500 错误页，
#      用户在页面上只看到"抱歉，出错了"）。
#   2. 模型回复里常带 ```json 围栏或前后解释文字，所以用正则抓第一个 JSON 对象，
#      而不是直接 JSON.parse 整段。
#   3. 具体到某条待确认的取舍：id 重复只留第一条——占位符无法区分同一个 id 的两条，
#      留多条只会让用户点到"另一条"的内容。
module DescriptionDraftPayload
  MAX_OPTIONS = Prompts::RequirementDraft::MAX_OPTIONS

  class << self
    # 从模型回复里抓 JSON 对象；抓不到或解析失败返回 nil
    def parse_json(content)
      json_match = content.to_s.match(/\{.*\}/m)
      return nil unless json_match

      parsed = JSON.parse(json_match[0])
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # 规范化待确认项：
    #   - 问题为空、非 Hash 的条目丢弃；
    #   - 有合法 id 的保留原 id；缺 id 的补**当前未占用的最小正整数**
    #     （不按数组下标补：被丢弃的噪音条目会白占号，补出来就不是"从 1 开始"了）；
    #   - id 重复只保留第一条；
    #   - options 截断到 MAX_OPTIONS 个并丢掉空串。
    def normalize_questions(raw)
      items = Array(raw).filter_map do |item|
        next unless item.is_a?(Hash)

        question = item['question'].to_s.strip
        next if question.empty?

        id = item['id']
        {
          id: id.is_a?(Integer) && id.positive? ? id : nil,
          question: question,
          options: Array(item['options']).map { |option| option.to_s.strip }.reject(&:empty?).first(MAX_OPTIONS)
        }
      end

      used_ids = items.filter_map { |item| item[:id] }
      items.each do |item|
        next if item[:id]

        next_number = 1
        next_number += 1 while used_ids.include?(next_number)
        item[:id] = next_number
        used_ids << next_number
      end

      seen_ids = {}
      items.select { |item| seen_ids[item[:id]] ? false : (seen_ids[item[:id]] = true) }
    end

    # 保证每个待确认项在 description 里都有可回填的占位符，而且**尽量放进它提到的那一步里**。
    #
    # 隐性知识（用户报过）：原来的兜底是把漏写的占位符在描述**末尾**补一段"需要确认："，
    # 于是正文里那一处判据旁边看不到"这里还不确定"，用户得在正文与末尾清单之间来回对照；
    # 而模型提的问题通常自带步骤号（"步骤6 中 cluster worker 是否…"），完全放得回原位。
    # 所以：能从问题里认出步骤号的，就插到那一步的末尾；认不出来的才退回末尾汇总兜底。
    def ensure_placeholders(description, questions)
      missing = questions.reject { |question| description.include?(Prompts::RequirementDraft.placeholder(question[:id])) }
      return description if missing.empty?

      lines = description.to_s.split("\n", -1)
      leftovers = []

      missing.each do |question|
        line = "#{Prompts::RequirementDraft.placeholder(question[:id])}：#{question[:question]}"
        leftovers << question unless insert_into_referenced_step(lines, question[:question], line)
      end

      return lines.join("\n") if leftovers.empty?

      parts = [lines.join("\n"), '需要确认：']
      leftovers.each do |question|
        parts << "#{Prompts::RequirementDraft.placeholder(question[:id])}：#{question[:question]}"
      end
      parts.reject { |part| part.to_s.strip.empty? }.join("\n")
    end

    # 步骤标记：两边若干短横线、中间是序号（与提示词要求的格式一致）
    STEP_MARKER = /-{2,}\s*步骤\s*\d+\s*-{2,}/

    # "步骤6 中 …" → 6；认不出返回 nil
    def referenced_step_number(text)
      match = text.to_s.match(/步骤\s*(\d+)/)
      match && match[1].to_i
    end

    # 把一行插进指定步骤的末尾（该步骤最后一段文字之后、下一个步骤标记之前）。
    # 只在**带短横线的步骤标记**上匹配，避免把正文里"步骤6 中…"这种引用当成标记。
    def insert_into_referenced_step(lines, question_text, content)
      number = referenced_step_number(question_text)
      return false if number.nil?

      start_index = lines.index { |line| line.to_s.match?(/-{2,}\s*步骤\s*#{number}\s*-{2,}/) }
      return false if start_index.nil?

      next_marker = (start_index + 1...lines.length).find { |i| lines[i].to_s.match?(STEP_MARKER) }
      insert_at = next_marker || lines.length
      # 跳过块尾的空行，插在该步骤最后一行文字之后（而不是空中飘着）
      insert_at -= 1 while insert_at > start_index + 1 && lines[insert_at - 1].to_s.strip.empty?
      lines.insert(insert_at, content)
      true
    end

    def normalize_notes(raw)
      Array(raw).map { |note| note.to_s.strip }.reject(&:empty?)
    end
  end
end

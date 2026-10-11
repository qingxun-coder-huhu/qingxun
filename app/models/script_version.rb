# frozen_string_literal: true

require 'json'

# 脚本版本快照
#
# 业务逻辑：
#   每次脚本内容发生有意义的变化（自动生成 / 微调 / 自动保存 / 手动保存 / 标记调试完成 /
#   回滚）都存下一份整份内容的快照，脚本页据此查看历史并回滚。
#
# 隐性知识：
#   1. `source` 决定历史列表里怎么向用户解释这条版本的来历，取值必须在 SOURCES 内——
#      写成自由文本页面就没法归类，用户看到的就是一串"某次保存"。
#   2. `revision` 只在**同一脚本内**递增且唯一（DB 有 [script_id, revision] 唯一索引兜底），
#      跨脚本不保证连续；重复时宁可抛异常，也不要静默覆盖别人的历史。
#   3. JSON 字段用 same_content? 比对而不是 `==`：两边一个来自 DB（字符串键）、一个来自
#      参数（也可能是字符串键），逐字段比字符串化的 JSON 更稳，也避免"看起来没变又记一条"。
class ScriptVersion < ApplicationRecord
  SOURCES = %w[generated refined manual autosave debugged rollback].freeze

  SOURCE_LABELS = {
    'generated' => '自动生成',
    'refined' => '微调',
    'manual' => '手动保存',
    'autosave' => '自动保存',
    'debugged' => '标记调试完成',
    'rollback' => '回滚'
  }.freeze

  belongs_to :script
  belongs_to :user

  validates :revision, presence: true,
                       numericality: { only_integer: true, greater_than: 0 },
                       uniqueness: { scope: :script_id }
  validates :source, presence: true, inclusion: { in: SOURCES }

  scope :recent, -> { order(revision: :desc) }

  # 给页面显示的来源说明
  def source_label
    SOURCE_LABELS[source] || source
  end

  # 与一份待写入内容是否等价（相同就不必再写库，免得白刷 updated_at）
  def same_content?(attrs)
    return false unless name.to_s == attrs[:name].to_s
    return false unless description.to_s == attrs[:description].to_s
    return false unless code.to_s == attrs[:code].to_s
    return false unless publish_status.to_s == attrs[:publish_status].to_s
    return false unless same_spec?(attrs)

    [command_mapping, device_models, branch_scenarios].zip(
      [attrs[:command_mapping], attrs[:device_models], attrs[:branch_scenarios]]
    ).all? { |mine, theirs| json_signature(mine) == json_signature(theirs) }
  end

  # "同一份需求"吗？决定这次变化算不算一个新版本（见 ScriptVersionRecorder）。
  #
  # 隐性知识：参与判断的只有**描述**——主线描述，以及各分支的描述（顺序也算，因为分支面板的
  # 顺序就是用户写下的顺序）。分支的命令映射、"通过与否"是跑出来的产物，不算需求变化，所以
  # 这里只比 description，不比整个 branch_scenarios。
  def same_spec?(attrs)
    return false unless initial_prompt.to_s == attrs[:initial_prompt].to_s

    branch_descriptions(branch_scenarios) == branch_descriptions(attrs[:branch_scenarios])
  end

  private

  def branch_descriptions(scenarios)
    Array(scenarios).map do |scenario|
      scenario.is_a?(Hash) ? scenario['description'].to_s : scenario.to_s
    end
  end

  # JSON 字段的比对指纹：键统一成字符串并**排序**后再序列化。
  # 不这么做的话，同一份内容里键顺序不同（DB 回读 vs 参数解析）就会被判成"变了"，
  # 于是自动保存每次都记一条实际上没变的历史。
  def json_signature(value)
    return nil if value.nil?

    JSON.generate(sorted(value))
  end

  def sorted(value)
    case value
    when Hash
      value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = sorted(v) }
           .sort.to_h
    when Array
      value.map { |item| sorted(item) }
    else
      value
    end
  end
end

# frozen_string_literal: true

# 任务执行结果：一次任务里「某设备 × 某脚本」的执行记录。
#
# 一个任务会把若干脚本依次下发到若干设备，每条组合产出一行记录，
# 携带状态、收集到的日志与脚本返回的结构化结果（ScriptResult）。
class TaskExecution < ApplicationRecord
  STATUSES = %w[pending running completed failed].freeze

  belongs_to :task
  belongs_to :script
  belongs_to :network_element, primary_key: :id, foreign_key: :network_element_id

  validates :status, inclusion: { in: STATUSES }

  scope :ordered, -> { order(:network_element_id, :script_id) }

  def duration_seconds
    return nil unless duration_ms

    (duration_ms / 1000.0).round(2)
  end

  def success?
    status == 'completed'
  end
end

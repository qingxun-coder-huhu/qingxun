# frozen_string_literal: true

# 任务的一次执行（对齐本地客户端的 LocalTaskExecution）。
#
# 一个任务可以有多次执行；页面默认展示最新一次（Task#latest_run），历史执行按时间保留。
class TaskRun < ApplicationRecord
  STATUSES = %w[pending running completed failed].freeze
  TERMINAL = %w[completed failed].freeze

  belongs_to :task
  has_many :task_executions, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  scope :recent_first, -> { order(created_at: :desc) }

  def status_text
    { 'pending' => '待执行', 'running' => '执行中',
      'completed' => '已完成', 'failed' => '失败' }[status] || status
  end

  def terminal?
    TERMINAL.include?(status)
  end

  def running?
    status == 'running'
  end
end

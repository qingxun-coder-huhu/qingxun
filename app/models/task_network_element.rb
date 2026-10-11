# frozen_string_literal: true

# 任务-网元关联模型
#
# 业务逻辑：
# TaskNetworkElement模型表示任务与网元设备的关联关系，记录设备在任务中的执行详情。
# 支持设备级别的状态管理、结果存储和进度追踪，实现细粒度的任务控制。
#
# 执行流程：
# 1. 任务开始：设备状态设为pending
# 2. 设备执行：状态变为running，记录开始时间
# 3. 执行完成：状态变为success/failed，记录完成时间和结果
# 4. 结果存储：保存输出内容、错误信息和执行统计
#
# 隐性知识：
# 1. 设备执行顺序通过sequence字段控制，支持复杂的执行拓扑
# 2. 跳过执行（skipped）的设备不计入失败统计，但记录跳过原因
# 3. 输出内容可能包含大量数据，需要定期清理或归档
# 4. 客户端模式下，client_device_id关联客户端本地存储的设备信息
#
class TaskNetworkElement < ApplicationRecord
  # 关联关系
  belongs_to :task
  belongs_to :network_element
  
  # 序列化JSON字段（注释掉，因为JSON列原生支持序列化）
  # serialize :result, JSON
  
  # 枚举定义：执行状态
  enum :status, {
    pending: 'pending',
    running: 'running',
    success: 'success',
    failed: 'failed',
    skipped: 'skipped'
  }, default: :pending
  
  # 数据验证
  validates :task_id, presence: true
  validates :network_element_id, presence: true
  validates :status, presence: true
  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :retry_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :duration, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  
  # 唯一性约束：同一任务中不能重复添加同一设备
  validates :network_element_id, uniqueness: { scope: :task_id, message: "设备已添加到任务中" }
  
  # 自定义验证
  validate :validate_result_format
  validate :validate_skip_reason, if: -> { skipped? && skip_reason.blank? }
  
  # 回调
  before_validation :set_default_sequence, if: -> { new_record? && sequence.blank? }
  before_save :calculate_duration, if: -> { started_at.present? && completed_at.present? }
  after_save :update_task_progress, if: -> { saved_change_to_status? && (success? || failed? || skipped?) }
  after_update :increment_script_stats, if: -> { saved_change_to_status? && (success? || failed?) }
  
  # 状态机方法
  
  # 开始执行设备任务
  def start!
    with_lock do
      raise "设备状态必须为pending才能开始执行" unless pending?
      
      update!(
        status: :running,
        started_at: Time.current,
        retry_count: 0,
        error_message: nil
      )
    end
  end
  
  # 设备执行成功
  # 参数：output - 执行输出内容, result_data - 详细结果数据
  def succeed!(output: nil, result_data: {})
    with_lock do
      raise "设备状态必须为running才能标记成功" unless running?
      
      update!(
        status: :success,
        completed_at: Time.current,
        output: output,
        result: result_data.merge(exit_code: 0, timestamp: Time.current.iso8601)
      )
    end
  end
  
  # 设备执行失败
  # 参数：error_message - 错误信息, output - 执行输出内容
  def fail!(error_message, output: nil)
    with_lock do
      raise "设备状态必须为running才能标记失败" unless running?
      
      update!(
        status: :failed,
        completed_at: Time.current,
        error_message: error_message,
        output: output,
        result: { exit_code: 1, error: error_message, timestamp: Time.current.iso8601 }
      )
    end
  end
  
  # 跳过设备执行
  # 参数：reason - 跳过原因
  def skip!(reason)
    with_lock do
      raise "设备状态必须为pending才能跳过" unless pending?
      
      update!(
        status: :skipped,
        completed_at: Time.current,
        skip_reason: reason
      )
    end
  end
  
  # 重试设备执行
  # 重置状态为pending，增加重试计数
  def retry!
    with_lock do
      raise "只有失败状态才能重试" unless failed?
      
      update!(
        status: :pending,
        started_at: nil,
        completed_at: nil,
        duration: nil,
        error_message: nil,
        output: nil,
        result: {},
        retry_count: retry_count + 1
      )
    end
  end
  
  # 类方法
  
  # 按状态统计设备执行情况
  def self.stats_by_status(task_id = nil)
    query = all
    query = query.where(task_id: task_id) if task_id
    
    query.group(:status).count
  end
  
  # 获取执行时间最长的设备
  def self.longest_running(limit: 10)
    where.not(started_at: nil)
         .where(completed_at: nil)
         .order(started_at: :asc)
         .limit(limit)
  end
  
  # 实例方法
  
  # 设备显示名称（包含任务上下文）
  def display_name
    "#{network_element.display_name} (任务: #{task.name})"
  end
  
  # 执行时长（如果已完成）
  def execution_duration
    return nil unless started_at && completed_at
    completed_at - started_at
  end
  
  # 是否超时
  def timed_out?(timeout_seconds = 300)
    return false unless running? && started_at
    
    Time.current - started_at > timeout_seconds
  end
  
  # 获取设备执行摘要
  def summary
    {
      device_id: network_element_id,
      device_name: network_element.name,
      status: status,
      duration: duration,
      started_at: started_at&.iso8601,
      completed_at: completed_at&.iso8601,
      error_message: error_message,
      skip_reason: skip_reason,
      retry_count: retry_count
    }
  end
  
  private
  
  # 设置默认执行顺序
  def set_default_sequence
    max_sequence = TaskNetworkElement.where(task_id: task_id).maximum(:sequence) || -1
    self.sequence = max_sequence + 1
  end
  
  # 计算执行时长
  def calculate_duration
    self.duration = completed_at - started_at if started_at && completed_at
  end
  
  # 更新任务进度
  def update_task_progress
    task.update_progress_if_needed
  end
  
  # 增加脚本统计
  def increment_script_stats
    # 这里需要实现：根据设备执行结果更新相关脚本的统计信息
    # 实际业务中需要关联到具体的脚本执行记录
  end
  
  # 验证结果格式
  def validate_result_format
    return if result.blank?
    
    unless result.is_a?(Hash)
      errors.add(:result, "必须是JSON对象格式")
    end
  end
  
  # 验证跳过原因
  def validate_skip_reason
    if skipped? && skip_reason.blank?
      errors.add(:skip_reason, "跳过执行必须提供原因")
    end
  end
end
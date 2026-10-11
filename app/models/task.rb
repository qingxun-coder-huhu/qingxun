# frozen_string_literal: true

# 任务模型
#
# 业务逻辑：
# Task模型代表用户创建的批量设备自动化任务，是清巡平台的核心执行单元。
# 支持复杂的任务编排：多设备并行、多脚本串行/并行、条件执行、参数化配置等。
# 根据架构设计，支持云端执行和客户端执行两种模式，保护敏感信息。
#
# 架构演进：
# 1. 原有系统：基于文件系统的任务存储，使用Qingxun::TaskManager执行
# 2. 新系统：数据库存储，支持状态管理、进度追踪、用户隔离
# 3. 兼容性：保持与现有TaskManager的集成，支持渐进式迁移
#
# 隐性知识：
# 1. 任务状态机严格控制任务生命周期，防止状态不一致
# 2. 进度计算基于设备-脚本组合，支持细粒度进度追踪
# 3. 执行参数支持复杂配置，如超时、重试、并行度、条件判断
# 4. 客户端模式下，云端只存储任务定义和结果，不参与实际执行
#
class Task < ApplicationRecord
  # 关联关系
  belongs_to :user
  
  # 任务与设备的多对多关联
  has_many :task_network_elements, dependent: :destroy
  has_many :network_elements, through: :task_network_elements
  
  # 任务与脚本的多对多关联
  has_many :task_scripts, dependent: :destroy
  has_many :scripts, through: :task_scripts

  # 执行结果（每台设备 × 每个脚本一条）
  has_many :task_executions, dependent: :destroy

  # 执行历史：一个任务可有多次执行（对齐客户端 LocalTask 1→N LocalTaskExecution）
  has_many :task_runs, dependent: :destroy

  # 最新一次执行
  def latest_run
    task_runs.recent_first.first
  end
  
  # 序列化JSON字段（注释掉，因为JSON列原生支持序列化）
  # serialize :execution_params, JSON
  # serialize :result, JSON
  
  # 枚举定义
  enum :status, {
    pending: 'pending',
    running: 'running',
    completed: 'completed',
    failed: 'failed',
    cancelled: 'cancelled'
  }, default: :pending
  
  enum :execution_mode, {
    cloud: 'cloud',
    client: 'client'
  }, default: :cloud
  
  # 数据验证
  validates :name, presence: true, length: { maximum: 100 }
  validates :status, presence: true
  validates :execution_mode, presence: true
  validates :user_id, presence: true
  validates :progress, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :device_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :script_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  
  # 唯一性约束：同一用户下的任务名称必须唯一
  validates :name, uniqueness: { scope: :user_id, message: "该任务名称已存在" }
  
  # 自定义验证
  validate :validate_execution_params
  validate :validate_result_format
  validate :validate_status_transition, on: :update
  
  # 回调
  before_validation :calculate_counts, if: -> { new_record? || task_network_elements.any? || task_scripts.any? }
  before_update :update_progress_if_needed
  after_update :notify_status_change, if: :saved_change_to_status?
  after_update :update_completion_timestamps, if: -> { saved_change_to_status? && (completed? || failed? || cancelled?) }
  
  # 状态机方法
  
  # 开始执行任务
  # 前置条件：任务状态必须为pending
  # 后置条件：更新状态为running，记录开始时间
  def start!
    with_lock do
      raise "任务状态必须为pending才能开始执行" unless pending?
      
      update!(
        status: :running,
        started_at: Time.current,
        progress: 0,
        error_message: nil
      )
    end
  end
  
  # 完成任务（成功）
  # 前置条件：任务状态必须为running
  # 后置条件：更新状态为completed，记录完成时间，进度设为100%
  def complete!
    with_lock do
      raise "任务状态必须为running才能完成" unless running?
      
      update!(
        status: :completed,
        completed_at: Time.current,
        progress: 100
      )
    end
  end
  
  # 任务失败
  # 参数：error_message - 错误信息
  # 前置条件：任务状态必须为running
  def fail!(error_message)
    with_lock do
      raise "任务状态必须为running才能标记失败" unless running?
      
      update!(
        status: :failed,
        completed_at: Time.current,
        error_message: error_message
      )
    end
  end
  
  # 取消任务
  # 前置条件：任务状态必须为pending或running
  def cancel!
    with_lock do
      raise "任务状态必须为pending或running才能取消" unless pending? || running?
      
      update!(
        status: :cancelled,
        completed_at: Time.current
      )
    end
  end
  
  # 更新执行进度
  # 参数：新的进度值（0-100）
  def update_progress(new_progress)
    new_progress = [[new_progress, 0].max, 100].min
    
    with_lock do
      update!(progress: new_progress) if running?
    end
  end
  
  # 类方法
  
  # 搜索任务
  def self.search(query: nil, user_id: nil, status: nil, execution_mode: nil, date_range: nil)
    result = all
    
    # 用户范围
    result = result.where(user_id: user_id) if user_id
    
    # 状态筛选
    result = result.where(status: status) if status.present?
    
    # 执行模式筛选
    result = result.where(execution_mode: execution_mode) if execution_mode.present?
    
    # 时间范围筛选
    if date_range.present?
      start_date, end_date = date_range
      result = result.where(created_at: start_date..end_date)
    end
    
    # 关键词搜索
    if query.present?
      result = result.where("name LIKE ? OR description LIKE ?", "%#{query}%", "%#{query}%")
    end
    
    result.order(created_at: :desc)
  end
  
  # 统计用户任务数据
  def self.user_statistics(user_id)
    tasks = where(user_id: user_id)
    
    {
      total: tasks.count,
      pending: tasks.pending.count,
      running: tasks.running.count,
      completed: tasks.completed.count,
      failed: tasks.failed.count,
      cancelled: tasks.cancelled.count,
      cloud_mode: tasks.cloud.count,
      client_mode: tasks.client.count
    }
  end
  
  # 实例方法
  
  # 任务显示名称
  def display_name
    "#{name} (#{status_i18n})"
  end
  
  # 状态的中文翻译
  def status_i18n
    I18n.t("task.statuses.#{status}", default: status.humanize)
  end
  
  # 执行模式的中文翻译
  def execution_mode_i18n
    I18n.t("task.execution_modes.#{execution_mode}", default: execution_mode.humanize)
  end
  
  # 执行时长（秒）
  def duration
    return nil unless started_at && completed_at
    completed_at - started_at
  end
  
  # 是否超时
  def timed_out?
    return false unless running? && started_at && execution_params['timeout']
    
    Time.current - started_at > execution_params['timeout']
  end
  
  # 添加设备到任务
  def add_network_element(network_element, sequence: nil, client_device_id: nil)
    TaskNetworkElement.create!(
      task: self,
      network_element: network_element,
      sequence: sequence || task_network_elements.count,
      client_device_id: client_device_id
    )
    
    calculate_counts
    save!
  end
  
  # 添加脚本到任务
  def add_script(script, sequence: 0, parameters: {}, condition: nil)
    TaskScript.create!(
      task: self,
      script: script,
      sequence: sequence,
      parameters: parameters,
      condition: condition
    )
    
    calculate_counts
    save!
  end
  
  # 生成任务定义JSON（兼容原有系统）
  def to_definition_json
    {
      name: name,
      description: description,
      execution_mode: execution_mode,
      execution_params: execution_params,
      devices: network_elements.map(&:task_info),
      scripts: scripts.map do |script|
        task_script = task_scripts.find_by(script_id: script.id)
        {
          id: script.id,
          name: script.name,
          sequence: task_script.sequence,
          parameters: task_script.parameters,
          condition: task_script.condition
        }
      end,
      created_at: created_at.iso8601,
      updated_at: updated_at.iso8601
    }
  end
  
  # 任务标识符
  def identifier
    "task_#{id}_#{Digest::MD5.hexdigest("#{user_id}#{name}#{created_at.to_i}")[0..7]}"
  end
  
  private
  
  # 计算设备数量和脚本数量
  def calculate_counts
    self.device_count = task_network_elements.count
    self.script_count = task_scripts.count
  end
  
  # 验证执行参数格式
  def validate_execution_params
    return if execution_params.blank?
    
    unless execution_params.is_a?(Hash)
      errors.add(:execution_params, "必须是JSON对象格式")
      return
    end
    
    # 验证超时时间（如果存在）
    if execution_params['timeout'].present?
      unless execution_params['timeout'].is_a?(Numeric) && execution_params['timeout'] > 0
        errors.add(:execution_params, "timeout必须是大于0的数字")
      end
    end
    
    # 验证重试次数（如果存在）
    if execution_params['retry_count'].present?
      unless execution_params['retry_count'].is_a?(Integer) && execution_params['retry_count'] >= 0
        errors.add(:execution_params, "retry_count必须是非负整数")
      end
    end
    
    # 验证并行度（如果存在）
    if execution_params['parallel_level'].present?
      unless execution_params['parallel_level'].is_a?(Integer) && execution_params['parallel_level'] > 0
        errors.add(:execution_params, "parallel_level必须是大于0的整数")
      end
    end
  end
  
  # 验证结果格式
  def validate_result_format
    return if result.blank?
    
    unless result.is_a?(Hash)
      errors.add(:result, "必须是JSON对象格式")
      return
    end
  end
  
  # 验证状态转换
  def validate_status_transition
    return unless status_changed?
    
    old_status = status_was.to_sym
    new_status = status.to_sym
    
    # 允许的状态转换
    #
    # 隐性知识：开源版允许**重复运行**，因此已结束的状态（completed/failed/cancelled）
    # 可以再次回到 running/pending。线上版此处是终态设计，这里是有意的差异。
    valid_transitions = {
      pending: [:running, :cancelled],
      running: [:completed, :failed, :cancelled],
      completed: [:running, :pending],
      failed: [:running, :pending],
      cancelled: [:running, :pending]
    }
    
    unless valid_transitions[old_status]&.include?(new_status)
      errors.add(:status, "不允许从 #{old_status} 转换为 #{new_status}")
    end
  end
  
  # 更新进度（如果需要）
  def update_progress_if_needed
    return unless running? && task_network_elements.any? && task_scripts.any?
    
    # 计算实际进度
    total_combinations = device_count * script_count
    return if total_combinations.zero?
    
    completed_combinations = task_network_elements.where(status: [:success, :failed, :skipped]).count
    new_progress = (completed_combinations.to_f / total_combinations * 100).round
    
    self.progress = new_progress if new_progress != progress
  end
  
  # 通知状态变化
  def notify_status_change
    # 实际业务中可能发送邮件、WebSocket通知等
    Rails.logger.info "任务 #{identifier} 状态从 #{status_was} 变为 #{status}"
  end
  
  # 更新完成时间戳
  def update_completion_timestamps
    self.completed_at ||= Time.current
  end
end
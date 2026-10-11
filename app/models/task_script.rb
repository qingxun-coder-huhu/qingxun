# frozen_string_literal: true

# 任务-脚本关联模型
#
# 业务逻辑：
# TaskScript模型表示任务与脚本的关联关系，控制脚本在任务中的执行逻辑。
# 支持复杂的任务编排：脚本执行顺序、条件执行、参数传递、结果验证等。
#
# 执行控制：
# 1. 顺序控制：通过sequence字段确定执行顺序，相同sequence值的脚本并行执行
# 2. 条件执行：condition字段支持Ruby表达式，根据前置结果决定是否执行
# 3. 参数传递：parameters字段支持JSON配置，可包含动态变量
# 4. 结果验证：expected_result字段定义脚本执行的期望结果
#
# 隐性知识：
# 1. 条件表达式中的变量包括：device（当前设备）、previous_results（前置脚本结果）、task（任务对象）
# 2. 参数支持变量替换，如{device_ip}、{device_name}，在运行时解析
# 3. 脚本统计信息（average_duration等）用于任务预计时长计算
# 4. 公开脚本可以被其他用户的任务引用，但参数可能不同
#
class TaskScript < ApplicationRecord
  # 关联关系
  belongs_to :task
  belongs_to :script
  
  # 序列化JSON字段（注释掉，因为JSON列原生支持序列化）
  # serialize :parameters, JSON
  
  # 枚举定义：执行状态
  enum :status, {
    pending: 'pending',
    running: 'running',
    success: 'success',
    failed: 'failed',
    skipped: 'skipped'
  }, default: :pending
  
  # 枚举定义：预期结果
  enum :expected_result, {
    any: 'any',
    expect_success: 'expect_success',
    warning: 'warning',
    info: 'info'
  }, default: :expect_success
  
  # 数据验证
  validates :task_id, presence: true
  validates :script_id, presence: true
  validates :status, presence: true
  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :expected_result, presence: true
  validates :average_duration, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :success_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :failure_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  
  # 唯一性约束：同一任务中不能重复添加同一脚本（相同sequence允许不同参数）
  validates :script_id, uniqueness: { scope: [:task_id, :sequence], message: "相同顺序的脚本已存在" }
  
  # 自定义验证
  validate :validate_parameters_format
  validate :validate_condition_syntax, if: -> { condition.present? }
  validate :validate_script_compatibility
  
  # 回调
  before_validation :set_default_parameters, if: -> { new_record? && parameters.blank? }
  after_save :update_script_usage, if: -> { saved_change_to_status? && (success? || failed?) }
  after_update :recalculate_average_duration, if: -> { saved_change_to_status? && (success? || failed?) }
  
  # 状态机方法
  
  # 开始执行脚本
  def start!
    with_lock do
      raise "脚本状态必须为pending才能开始执行" unless pending?
      
      update!(status: :running)
    end
  end
  
  # 脚本执行成功
  def succeed!
    with_lock do
      raise "脚本状态必须为running才能标记成功" unless running?
      
      update!(
        status: :success,
        skip_reason: nil
      )
    end
  end
  
  # 脚本执行失败
  def fail!
    with_lock do
      raise "脚本状态必须为running才能标记失败" unless running?
      
      update!(
        status: :failed,
        skip_reason: nil
      )
    end
  end
  
  # 跳过脚本执行
  # 参数：reason - 跳过原因
  def skip!(reason)
    with_lock do
      raise "脚本状态必须为pending才能跳过" unless pending?
      
      update!(
        status: :skipped,
        skip_reason: reason
      )
    end
  end
  
  # 类方法
  
  # 按任务和顺序分组统计
  def self.stats_by_task_and_sequence
    group(:task_id, :sequence)
      .select(:task_id, :sequence, 'COUNT(*) as script_count', 'AVG(average_duration) as avg_duration')
      .order(:task_id, :sequence)
  end
  
  # 查找有条件执行的脚本
  def self.with_conditions
    where.not(condition: nil)
  end
  
  # 实例方法
  
  # 脚本显示名称（包含任务和顺序上下文）
  def display_name
    "顺序 #{sequence}: #{script.name}"
  end
  
  # 解析执行参数（替换变量）
  # 参数：context - 包含替换变量的上下文哈希
  # 返回：解析后的参数哈希
  def parsed_parameters(context = {})
    return parameters if parameters.blank? || context.blank?
    
    # 深度复制参数以避免修改原始数据
    parsed = parameters.deep_dup
    
    # 递归替换变量
    replace_variables(parsed, context)
    
    parsed
  end
  
  # 评估执行条件
  # 参数：context - 包含条件变量的上下文哈希
  # 返回：布尔值，表示是否满足执行条件
  def evaluate_condition(context = {})
    return true if condition.blank?
    
    # 安全地评估Ruby表达式
    safe_eval(condition, context)
  rescue => e
    Rails.logger.error "条件评估失败: #{e.message}, 条件: #{condition}"
    false
  end
  
  # 验证结果是否符合预期
  # 参数：actual_result - 实际执行结果（字符串或符号）
  # 返回：布尔值，表示结果是否符合预期
  def result_matches_expectation?(actual_result)
    case expected_result.to_sym
    when :any
      true
    when :expect_success
      actual_result.to_sym == :success
    when :warning
      [:success, :warning].include?(actual_result.to_sym)
    when :info
      [:success, :warning, :info].include?(actual_result.to_sym)
    else
      false
    end
  end
  
  # 更新统计信息（成功）
  def record_success(duration)
    new_success_count = success_count + 1
    new_average = calculate_new_average(average_duration, duration, new_success_count)
    
    update!(
      success_count: new_success_count,
      average_duration: new_average
    )
  end
  
  # 更新统计信息（失败）
  def record_failure
    update!(failure_count: failure_count + 1)
  end
  
  # 获取脚本执行摘要
  def summary
    {
      script_id: script_id,
      script_name: script.name,
      sequence: sequence,
      status: status,
      expected_result: expected_result,
      condition: condition,
      average_duration: average_duration,
      success_count: success_count,
      failure_count: failure_count,
      skip_reason: skip_reason
    }
  end
  
  private
  
  # 设置默认参数
  #
  # 隐性知识：脚本的 command_mapping 在本项目里是**数组**（命令树），而 parameters
  # 要求是 JSON 对象。早先无条件把 command_mapping 赋给 parameters，导致用数组映射
  # 的脚本一建任务就报 "Parameters 必须是JSON对象格式"。这里只在它确实是个 Hash 时才用。
  def set_default_parameters
    mapping = script&.command_mapping
    self.parameters = mapping.is_a?(Hash) ? mapping : {}
  end
  
  # 更新脚本使用次数
  def update_script_usage
    script.increment_usage if success?
  end
  
  # 重新计算平均执行时长
  def recalculate_average_duration
    # 这里需要根据实际执行记录重新计算平均时长
    # 实际业务中可能需要关联到设备执行记录
  end
  
  # 验证参数格式
  def validate_parameters_format
    return if parameters.blank?
    
    unless parameters.is_a?(Hash)
      errors.add(:parameters, "必须是JSON对象格式")
    end
  end
  
  # 验证条件语法
  def validate_condition_syntax
    # 简单语法检查：确保条件表达式是有效的Ruby代码片段
    begin
      RubyVM::InstructionSequence.compile("true if #{condition}")
    rescue SyntaxError => e
      errors.add(:condition, "语法错误: #{e.message}")
    end
  end
  
  # 验证脚本兼容性
  def validate_script_compatibility
    return unless task && script

    # 检查脚本是否适用于任务的设备型号
    task_device_models = task.network_elements.pluck(:device_model).uniq.compact
    script_device_models = script.device_models || []

    if script_device_models.present? && task_device_models.present?
      compatible = (task_device_models & script_device_models).any?
      errors.add(:script_id, "脚本不适用于任务中的设备型号") unless compatible
    end
  end
  
  # 递归替换变量
  def replace_variables(obj, context)
    case obj
    when String
      # 替换 {variable} 格式的变量
      context.each do |key, value|
        placeholder = "{#{key}}"
        obj = obj.gsub(placeholder, value.to_s) if obj.include?(placeholder)
      end
      obj
    when Hash
      obj.each { |k, v| obj[k] = replace_variables(v, context) }
    when Array
      obj.map { |v| replace_variables(v, context) }
    else
      obj
    end
  end
  
  # 安全评估Ruby表达式
  def safe_eval(code, context)
    # 创建安全的绑定环境
    bind = binding
    
    # 将上下文变量注入绑定环境
    context.each do |key, value|
      bind.local_variable_set(key.to_sym, value)
    end
    
    # 评估表达式
    bind.eval(code)
  end
  
  # 计算新的平均值
  def calculate_new_average(current_avg, new_value, new_count)
    return new_value if current_avg.nil? || new_count == 1
    
    (current_avg * (new_count - 1) + new_value) / new_count
  end
end
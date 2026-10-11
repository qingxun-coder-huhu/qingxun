# frozen_string_literal: true

require 'thread'
require 'json'
require 'time'
require 'singleton'

require 'thread'
require 'json'
require 'time'
require 'singleton'

require 'thread'
require 'json'
require 'time'

# 任务执行内存状态管理器
# 管理内存中的所有正在执行的任务状态
# 页面获取任务状态时从内存中读取
class TaskExecutionManager
  include Singleton

  def initialize
    @mutex = Mutex.new
    # 内存中的任务状态存储: { execution_id => task_state }
    @running_tasks = {}
    # 任务状态回调订阅者
    @subscribers = []
  end

  # 添加任务到内存
  # @param execution_id [String] 执行记录ID
  # @param task_state [Hash] 任务初始状态
  def add_task(execution_id, task_state)
    key = execution_id.to_s
    puts "[TaskExecutionManager] add_task called, key=#{key}, current keys=#{@running_tasks.keys.inspect}"
    @mutex.synchronize do
      @running_tasks[key] = {
        execution_id: key,
        task_id: task_state[:task_id] || task_state['task_id'],
        status: task_state[:status] || task_state['status'] || 'running',
        progress: task_state[:progress] || task_state['progress'] || 0,
        started_at: task_state[:started_at] || task_state['started_at'] || Time.now.iso8601,
        execution_units: task_state[:execution_units] || task_state['execution_units'] || {},
        updated_at: Time.now.iso8601
      }
      puts "[TaskExecutionManager] Task added, keys now=#{@running_tasks.keys.inspect}"
    end
    notify_subscribers(key, :added)
  end

  # 更新任务状态
  # @param execution_id [String] 执行记录ID
  # @param updates [Hash] 要更新的字段
  def update_task(execution_id, updates)
    key = execution_id.to_s
    task = nil
    @mutex.synchronize do
      return unless @running_tasks.key?(key)
      @running_tasks[key].merge!(updates)
      @running_tasks[key][:updated_at] = Time.now.iso8601
      task = @running_tasks[key].dup
    end
    notify_subscribers(key, :updated, task)
  end

  # 更新脚本执行状态
  # @param execution_id [String] 执行记录ID
  # @param device_id [String] 设备ID
  # @param script_id [String] 脚本ID
  # @param status [String] 脚本状态
  # @param options [Hash] 其他选项
  def update_script_status(execution_id, device_id, script_id, status, **options)
    key = execution_id.to_s
    task = nil
    @mutex.synchronize do
      return unless @running_tasks.key?(key)

      task_state = @running_tasks[key]
      units = task_state[:execution_units] || task_state['execution_units'] || {}

      # 兼容符号键和字符串键
      device_key = units.key?(device_id) ? device_id : device_id.to_s
      return unless units[device_key]

      scripts = units[device_key]
      scripts_key = scripts.key?('scripts') ? 'scripts' : :scripts
      return unless scripts[scripts_key]

      script_list = scripts[scripts_key]
      script_key = script_list.key?(script_id) ? script_id : script_id.to_s
      return unless script_list[script_key]

      script_info = script_list[script_key]

      # 更新脚本状态
      script_info['status'] = status
      # 终态都要落 completed_at 与结论字段。这里漏一个状态，那种脚本的检查点结论就丢了
      # （报告页的「检查点结论」列会空着）；四态：completed/partial/failed/error。
      case status
      when 'running'
        script_info['started_at'] = Time.now.iso8601
      when 'completed', 'partial', 'failed', 'error'
        script_info['completed_at'] = Time.now.iso8601
        script_info['conclusion'] = options[:conclusion] if options[:conclusion]
        script_info['output'] = options[:output] if options[:output]
        script_info['error'] = options[:error] if options[:error]
        # 报告页要展示检查点结论，内存状态里也得留一份
        script_info['checkpoints'] = options[:checkpoints] if options[:checkpoints]
      end

      task_state[:updated_at] = Time.now.iso8601
      task = task_state.dup
    end
    notify_subscribers(key, :script_updated, task)
  end

  # 更新某个**设备**的流程状态。
  #
  # 业务逻辑：
  #   "设备跑没跑成"是设备级的事：登录成功、脚本都尝试过了就是 completed（界面显示"执行完成"），
  #   登录不上才是 failed（界面显示"登录失败"）。脚本与检查点的判定结果不代表设备状态 ——
  #   一台设备"巡检结论不好"和"这台设备根本没连上"是两回事。
  #
  # 隐性知识：
  #   1. 这个状态以前**没人写**：前端只能拿"所有脚本是否成功"去猜设备状态，于是
  #      "跑完了但脚本判定失败"的设备被显示成失败。现在就地把设备级结果写进内存状态。
  #   2. 只更新内存：任务结束时的 complete_from_memory! 会把整份 units 落库，
  #      中途的读取走 to_api_hash 的 merge_mem_state（它会合并设备 status）。
  def update_device_status(execution_id, device_id, status, **options)
    key = execution_id.to_s
    task = nil
    @mutex.synchronize do
      return unless @running_tasks.key?(key)

      task_state = @running_tasks[key]
      units = task_state[:execution_units] || task_state['execution_units'] || {}
      device_key = units.key?(device_id) ? device_id : device_id.to_s
      unit = units[device_key]
      return unless unit

      unit['status'] = status
      case status
      when 'running'
        unit['started_at'] = Time.now.iso8601
      when 'completed', 'failed'
        unit['completed_at'] = Time.now.iso8601
        unit['error'] = options[:error] if options[:error]
      end

      task_state[:updated_at] = Time.now.iso8601
      task = task_state.dup
    end
    notify_subscribers(key, :device_updated, task)
  end

  # 更新任务进度
  # @param execution_id [String] 执行记录ID
  # @param progress [Integer] 进度值 0-100
  def update_progress(execution_id, progress)
    update_task(execution_id, progress: [0, [progress, 100].min].max)
  end

  # 从内存中移除任务
  # @param execution_id [String] 执行记录ID
  def remove_task(execution_id)
    key = execution_id.to_s
    task = nil
    @mutex.synchronize do
      puts "[TaskExecutionManager] remove_task called, key=#{key}"
      task = @running_tasks.delete(key)
    end
    notify_subscribers(key, :removed) if task
  end

  # 获取单个任务状态
  # @param execution_id [String] 执行记录ID
  # @return [Hash, nil] 任务状态
  def get_task(execution_id)
    key = execution_id.to_s
    @mutex.synchronize do
      puts "[TaskExecutionManager] get_task called, key=#{key}, available keys=#{@running_tasks.keys.inspect}"
      @running_tasks[key]&.dup
    end
  end

  # 获取所有正在执行的任务
  # @return [Hash] 所有任务状态
  def get_all_running_tasks
    @mutex.synchronize do
      @running_tasks.transform_values(&:dup)
    end
  end

  # 检查任务是否在运行
  # @param execution_id [String] 执行记录ID
  # @return [Boolean]
  def task_running?(execution_id)
    key = execution_id.to_s
    @mutex.synchronize do
      @running_tasks.key?(key)
    end
  end

  # 订阅任务状态变化
  # @param block [Proc] 回调块
  def subscribe(&block)
    @mutex.synchronize do
      @subscribers << block
    end
  end

  # 取消订阅
  # @param block [Proc] 要取消的回调块
  def unsubscribe(&block)
    @mutex.synchronize do
      @subscribers.delete(block)
    end
  end

  private

  # 通知所有订阅者
  def notify_subscribers(execution_id, event_type, task = nil)
    subscribers = nil
    @mutex.synchronize do
      subscribers = @subscribers.dup
    end
    subscribers.each do |subscriber|
      begin
        subscriber.call(execution_id, event_type, task)
      rescue => e
        puts "[TaskExecutionManager] 通知订阅者失败: #{e.message}"
      end
    end
  end
end

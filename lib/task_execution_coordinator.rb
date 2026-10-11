# frozen_string_literal: true

require 'singleton'
require_relative 'task_execution_manager'
require_relative 'thread_pool_executor'
require_relative 'task_directory_preparer'
require_relative 'device_login_handler'
require_relative 'script_executor'
require_relative 'device_execution_processor'
require_relative 'task_finalizer'

# 任务执行协调器
# 单一职责：协调各个单一职责组件，完成任务执行流程
# 不再包含具体的业务逻辑，只负责流程编排
# 适配说明（相对客户端版）：去掉 Singleton——每个任务执行用一个协调器实例，
# 线程池大小可按连接池上限传入（客户端固定 20，在连接池更小的部署里会互相等待超时）。
class TaskExecutionCoordinator
  def initialize(pool_size: 20)
    @thread_pool = ThreadPoolExecutor.new(pool_size)
    @state_manager = TaskExecutionManager.instance
    @directory_preparer = TaskDirectoryPreparer.new
    @login_handler = DeviceLoginHandler.new
    @script_executor = ScriptExecutor.new
    @device_processor = DeviceExecutionProcessor.new(
      @state_manager, 
      @login_handler, 
      @script_executor
    )
    @finalizer = TaskFinalizer.new(@state_manager)
    @started = false
    @mutex = Mutex.new
  end

  # 启动协调器
  def start
    @mutex.synchronize do
      return if @started
      @thread_pool.start
      @started = true
      puts "[TaskExecutionCoordinator] 已启动，线程池大小: 20"
    end
  end

  # 停止协调器
  # @param wait [Boolean] 是否等待所有任务完成
  def stop(wait: true)
    @mutex.synchronize do
      return unless @started
      @thread_pool.stop(wait: wait)
      @started = false
      puts "[TaskExecutionCoordinator] 已停止"
    end
  end

  # 提交任务执行
  # @param local_task [LocalTask] 本地任务对象
  # @param execution [LocalTaskExecution] 执行记录对象
  def submit_task(local_task, execution)
    start unless @started

    # 1. 先准备目录结构（这会初始化 execution_units，生成 log_file_path）
    @directory_preparer.prepare(execution)

    # 2. 再获取完整的 execution_units（包含 log_file_path）
    execution_units = execution.get_execution_units

    # 3. 将任务添加到内存状态管理器
    @state_manager.add_task(execution.id, {
      task_id: local_task.id,
      status: 'running',
      progress: 0,
      started_at: execution.started_at&.iso8601,
      execution_units: execution_units
    })

    # 4. 提交执行单元到线程池
    submit_execution_units(execution.id, execution_units, execution)

    puts "[TaskExecutionCoordinator] 任务已提交: execution_id=#{execution.id}, 设备数=#{execution_units.size}"
  end

  private

  # 提交所有执行单元到线程池
  def submit_execution_units(execution_id, execution_units, execution)
    total_units = execution_units.size
    completed_units = 0

    execution_units.each do |device_id, device_unit|
      @thread_pool.submit do
        begin
          @device_processor.process(execution_id, device_id, device_unit, execution)
        ensure
          completed_units += 1
          update_progress(execution_id, completed_units, total_units)
          finalize_if_complete(execution_id, execution, completed_units, total_units)
        end
      end
    end
  end

  # 更新任务进度
  def update_progress(execution_id, completed, total)
    progress = (completed.to_f / total * 100).to_i
    @state_manager.update_progress(execution_id, progress)
  end

  # 如果所有单元都完成，则完成任务
  def finalize_if_complete(execution_id, execution, completed, total)
    @finalizer.finalize(execution) if completed >= total
  end
end

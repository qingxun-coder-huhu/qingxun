# frozen_string_literal: true

require_relative 'task_execution_adapter'

# 任务执行入口（应用侧薄封装）
#
# 编排逻辑**逐字复用**本地客户端的编排层：
#   `TaskExecutionCoordinator` → `DeviceExecutionProcessor` → `ScriptExecutor` / `DeviceLoginHandler`
#   → `TaskFinalizer`（收尾）；状态与目录由 `TaskExecutionAdapter` 映射到本应用的模型。
#
# 本类只负责：注册运行态、建适配器、提交给协调器、等执行结束后停掉线程池。
#
# 隐性知识：
#   1. 裸 Thread 不参与 Rails executor，借出的连接不会自动归还，线程结束要显式 release。
#   2. 协调器的线程池按连接池上限设置（客户端固定 20，池小会互相等待超时）。
#   3. 逐字复用编排层后**不再支持取消**（客户端编排没有取消机制）：`cancel` 保留为空实现。
class TaskRunner
  class << self
    def registry
      @registry ||= {}
    end

    def registry_mutex
      @registry_mutex ||= Mutex.new
    end

    def register(task_id, adapter)
      registry_mutex.synchronize { registry[task_id] = adapter }
    end

    def unregister(task_id)
      registry_mutex.synchronize { registry.delete(task_id) }
    end

    def running?(task_id)
      registry_mutex.synchronize { registry.key?(task_id) }
    end

    # 保留签名以免调用方报错；逐字复用客户端编排层后不支持中断
    def cancel(_task_id)
      false
    end

    def cancelled?(_task_id)
      false
    end

    # 后台执行（控制器调用）
    def start_async(task)
      Thread.new do
        begin
          new(task).call
        rescue StandardError => e
          Rails.logger.error("[TaskRunner] 后台执行异常：#{e.class}: #{e.message}")
        ensure
          ActiveRecord::Base.connection_pool.release_connection
        end
      end
    end
  end

  def initialize(task)
    @task = task
  end

  def call
    # 每次运行建一条执行记录（保留历史），执行单元归属到本次运行
    run = @task.task_runs.create!(status: 'running', progress: 0, started_at: Time.current)
    adapter = TaskExecutionAdapter.new(@task, run: run)
    self.class.register(@task.id, adapter)
    @task.update_columns(status: 'running', started_at: Time.current,
                         completed_at: nil, error_message: nil, progress: 0)

    coordinator = TaskExecutionCoordinator.new(pool_size: worker_count)
    coordinator.submit_task(@task, adapter)
    adapter.wait_until_done
    coordinator.stop(wait: false)
  ensure
    self.class.unregister(@task.id)
  end

  private

  # 线程数不超过数据库连接池，避免工作线程互相等待连接超时
  def worker_count
    configured = (QingxunConfig.execution[:max_concurrent_devices] || 4).to_i
    cap = [ActiveRecord::Base.connection_pool.size - 1, 1].max
    [[configured, 1].max, cap].min
  end
end

# frozen_string_literal: true

require_relative 'device_runner'

# 任务编排：把任务下的「设备 × 脚本」组合并发下发到真机执行，记录每条结果。
#
# 业务逻辑：
#   - 任务通过 task_network_elements / task_scripts 关联设备与脚本；
#   - 每个组合产出一行 TaskExecution（状态/日志/返回值）；
#   - 并发度取 config/qingxun.yml 的 execution.max_concurrent_devices；
#   - 实时更新任务进度，结束后置为 completed / failed。
#
# 隐性知识：
#   1. 设备 IO 很慢（登录 + 逐条命令），因此并发用线程实现；但数据库连接是稀缺资源，
#      每个工作线程用 connection_pool.with_connection 包住自己那份活，避免超发连接。
#   2. 长任务不该占住请求线程：控制器用 start_async 起后台线程，页面轮询进度。
class TaskRunner
  def initialize(task)
    @task = task
  end

  # 后台执行（控制器调用）
  def self.start_async(task)
    Thread.new { new(task).call }
  end

  def call
    @task.update!(status: 'running', started_at: Time.current, completed_at: nil,
                  error_message: nil, progress: 0)

    devices = ordered(@task.network_elements)
    scripts = ordered_scripts
    units = devices.product(scripts)

    if units.empty?
      @task.update!(status: 'failed', completed_at: Time.current, progress: 100,
                    error_message: '任务没有可执行的设备或脚本')
      return
    end

    concurrency = [(QingxunConfig.execution[:max_concurrent_devices] || 4).to_i, 1].max
    total = units.size
    done = 0
    failures = 0
    mutex = Mutex.new
    queue = Queue.new
    units.each { |u| queue << u }

    workers = [concurrency, total].min
    threads = Array.new(workers) do
      Thread.new do
        loop do
          unit = begin
            queue.pop(true)
          rescue ThreadError
            nil
          end
          break unless unit

          ok = process_unit(*unit)
          mutex.synchronize do
            done += 1
            failures += 1 unless ok
            @task.update_columns(progress: ((done * 100.0) / total).round)
          end
        end
      end
    end
    threads.each(&:join)

    @task.update!(
      status: failures.zero? ? 'completed' : 'failed',
      progress: 100,
      completed_at: Time.current,
      result: { total: total, failures: failures, succeeded: total - failures },
      error_message: failures.zero? ? nil : "#{failures}/#{total} 个执行项失败"
    )
  rescue StandardError => e
    @task.update!(status: 'failed', completed_at: Time.current, error_message: e.message)
  end

  private

  # 执行一个「设备 × 脚本」组合，写一行 TaskExecution。返回是否成功。
  def process_unit(device, script)
    ActiveRecord::Base.connection_pool.with_connection do
      exec = TaskExecution.find_or_initialize_by(
        task: @task, network_element_id: device.id, script_id: script.id
      )
      exec.update!(status: 'running', started_at: Time.current)

      outcome = DeviceRunner.new(device, script).run

      exec.update!(
        status: outcome[:success] ? 'completed' : 'failed',
        logs: Array(outcome[:logs]).join("\n"),
        result: outcome[:result] || {},
        error_message: outcome[:error],
        duration_ms: outcome[:duration_ms],
        finished_at: Time.current
      )
      outcome[:success]
    end
  end

  def ordered(relation)
    relation.order(:created_at).to_a
  end

  def ordered_scripts
    @task.scripts.order('task_scripts.sequence ASC, task_scripts.id ASC').to_a
  end
end

# frozen_string_literal: true

require 'securerandom'
require_relative '../../lib/file_path_utils'

# 任务执行适配器：把本应用的 `Task` 模型，适配成客户端编排层（TaskExecutionCoordinator /
# DeviceExecutionProcessor / TaskFinalizer）所需的「execution 对象」接口。
#
# 编排与执行逻辑**逐字复用**客户端的那几个类；本类只做：
#   - 提供 `execution_units`（设备 → {连接信息, 脚本{codename/code/user}}）；
#   - 把状态更新与最终结果落到本应用的 `TaskExecution` / `task_network_elements` / `Task`。
#
# 状态词表与客户端一致（脚本四态 completed/partial/failed/error），因此报告/状态页直接读得到。
class TaskExecutionAdapter
  WAIT_TIMEOUT = 3600

  attr_reader :id, :task, :run

  def initialize(task, run:)
    @task = task
    @run = run
    @id = "run-#{run.id}-#{SecureRandom.hex(4)}"
    @done = false
    @done_mutex = Mutex.new
  end

  # 用本次运行(run)的开始时间，保证 task_dir_name 可由 run 稳定复现（便于日志接口定位文件）
  def started_at
    (@run && @run.started_at) || @task.started_at || Time.current
  end

  # 客户端编排层用于组织日志目录（FileUtils 的 login/devlog 路径都基于它）
  def task_dir_name
    @task_dir_name ||= "task_#{@task.id}_#{started_at.strftime('%Y%m%d_%H%M%S')}"
  end

  def task_root_dir
    FilePathUtils.task_root_dir(task_dir_name, base_logs_dir: logs_base)
  end

  def get_execution_units
    @units ||= build_units
  end

  # 目录准备器会调用；写一份 JSON 状态到日志目录（与客户端一致，便于排查）
  def save_status_to_file
    FilePathUtils.ensure_dir_exists(task_root_dir)
    FilePathUtils.write_json_status(
      FilePathUtils.task_json_status_file_path(task_dir_name, base_logs_dir: logs_base),
      execution_units: get_execution_units
    )
  rescue StandardError
    nil
  end

  # 设备级流程状态落到 task_network_elements（用 update_columns 绕过其枚举/回调）
  def update_device_status!(device_id, status, **_opts)
    link = @task.task_network_elements.find_by(network_element_id: device_id.to_s)
    return unless link

    link.update_columns(status: device_status_for(status))
  rescue StandardError
    nil
  end

  # 脚本级状态落到 TaskExecution（客户端词表原样存）
  def update_script_status!(device_id, script_id, status, **opts)
    exec = TaskExecution.find_or_initialize_by(
      task_run: @run, network_element_id: device_id.to_s, script_id: script_id
    )
    exec.task = @task if exec.task_id.nil?
    exec.status = status.to_s
    exec.logs = opts[:output].to_s if opts.key?(:output)
    exec.error_message = opts[:error] if opts.key?(:error)
    if opts.key?(:conclusion) || opts.key?(:checkpoints)
      exec.result = { 'conclusion' => opts[:conclusion], 'checkpoints' => opts[:checkpoints] || [] }
    end

    terminal = %w[completed partial failed error].include?(status.to_s)
    exec.started_at ||= Time.current
    if terminal
      exec.finished_at ||= Time.current
      exec.duration_ms ||= ((exec.finished_at - exec.started_at) * 1000).to_i
    end
    exec.save!
  rescue StandardError => e
    Rails.logger.error("[TaskExecutionAdapter] 写脚本状态失败：#{e.class}: #{e.message}")
  end

  # 编排层完成时调用：把内存里的最终 units 统一落库，并写任务最终状态
  def complete_from_memory!(mem_state, success: true)
    units = mem_state[:execution_units] || mem_state['execution_units'] || {}
    persist_units(units)
    finalize_task(success: success)
  end

  def complete!(success: true)
    finalize_task(success: success)
  end

  def done?
    @done_mutex.synchronize { @done }
  end

  def wait_until_done(timeout: WAIT_TIMEOUT)
    deadline = Time.current + timeout
    sleep 0.1 until done? || Time.current > deadline
    done?
  end

  private

  def finalize_task(success:)
    # 任务状态只看"跑完了没有"（与客户端 TaskFinalizer 一致）
    status = success ? 'completed' : 'failed'
    # 本次执行落定
    @run.update_columns(status: status, progress: 100, completed_at: Time.current)
    # Task 上镜像最新一次执行的状态，供任务列表等读取
    @task.update_columns(status: status, progress: 100, completed_at: Time.current)
    @done_mutex.synchronize { @done = true }
  end

  # 内存态里的最终 units（含各脚本 status/conclusion/checkpoints/output）落库
  def persist_units(units)
    units.each do |device_id, unit|
      unit = unit.transform_keys(&:to_s) if unit.respond_to?(:transform_keys)
      scripts = unit['scripts'] || unit[:scripts] || {}
      scripts.each do |script_id, info|
        info = info.transform_keys(&:to_s) if info.respond_to?(:transform_keys)
        update_script_status!(
          device_id, script_id, info['status'] || 'failed',
          output: info['output'], error: info['error'],
          conclusion: info['conclusion'], checkpoints: info['checkpoints']
        )
      end
    end
  end

  def build_units
    units = {}
    scripts = @task.scripts.order('task_scripts.sequence ASC, task_scripts.id ASC').to_a

    @task.network_elements.each do |device|
      units[device.id.to_s] = {
        'name' => device.name,
        'device_ip' => device.ip_address,
        'device_model' => device.device_model,
        'description' => device.description,
        'connection_info' => connection_info(device),
        'login_log_path' => FilePathUtils.login_log_file_path(
          task_dir_name, device.ip_address.to_s, base_logs_dir: logs_base
        ),
        'scripts' => scripts.each_with_object({}) do |script, acc|
          acc[script.id.to_s] = {
            'name' => script.name,
            'script_name' => script.name,
            'code' => script.code,
            'user' => @task.user,
            'log_file_path' => FilePathUtils.devlog_file_path(
              task_dir_name, device.ip_address.to_s, script.name, base_logs_dir: logs_base
            )
          }
        end
      }
    end
    units
  end

  def connection_info(device)
    {
      'host' => device.ip_address,
      'port' => device.port,
      'connection_type' => device.connection_type,
      'username' => device.username,
      'password' => device.decrypt_password,
      'enable_command' => device.enable_command,
      'enable_password' => device.decrypt_enable_password,
      'root_password' => (device.decrypt_root_password if device.respond_to?(:decrypt_root_password))
    }
  end

  def device_status_for(status)
    { 'completed' => 'success', 'running' => 'running', 'failed' => 'failed', 'pending' => 'pending' }[status.to_s] || status.to_s
  end

  def logs_base
    Rails.root.join('logs').to_s
  end
end

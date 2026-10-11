# frozen_string_literal: true

# 任务报告数据生成（开源版）
#
# 结构对齐本地客户端的 ReportGenerator：task / statistics / devices / errors / flat_scripts，
# 报告页与 HTML 导出共用。数据来源是本应用的 Task + TaskExecution（每台设备 × 每个脚本一行）。
class ReportGenerator
  def self.call(task)
    new(task).generate
  end

  def initialize(task)
    @task = task
    @run = task.latest_run
    scope = @run ? @run.task_executions : task.task_executions
    @executions = scope.includes(:script, :network_element).to_a
  end

  def generate
    devices = devices_data
    {
      task: task_summary,
      statistics: calculate_statistics(devices),
      devices: devices,
      errors: collect_errors(devices),
      flat_scripts: flat_scripts(devices),
      generated_at: Time.current.iso8601
    }
  end

  private

  def task_summary
    status = @run ? @run.status : @task.status
    started_at = @run ? @run.started_at : @task.started_at
    completed_at = @run ? @run.completed_at : @task.completed_at
    {
      id: @task.id,
      run_id: @run&.id,
      name: @task.name,
      description: @task.description,
      status: status,
      status_text: execution_status_text(status),
      progress: @run ? @run.progress : @task.progress,
      created_at: @task.created_at&.iso8601,
      started_at: started_at&.iso8601,
      completed_at: completed_at&.iso8601,
      duration: human_duration(started_at, completed_at)
    }
  end

  def devices_data
    by_device = @executions.group_by(&:network_element_id)

    @task.network_elements.map do |device|
      execs = (by_device[device.id] || []).sort_by(&:script_id)
      scripts = execs.map { |e| script_data(e) }
      status = device_status(scripts)

      {
        id: device.id,
        name: device.name,
        device_ip: device.ip_address,
        device_model: device.device_model,
        description: device.description,
        status: status,
        status_text: device_status_text(status),
        scripts_count: scripts.size,
        scripts_success: scripts.count { |s| s[:status] == 'completed' },
        scripts_partial: scripts.count { |s| s[:status] == 'partial' },
        duration: device_duration(execs),
        scripts: scripts
      }
    end
  end

  def script_data(exec)
    result = exec.result.is_a?(Hash) ? exec.result : {}
    checkpoints = normalize_checkpoints(result['checkpoints'])
    status = display_status(exec, result)

    {
      id: exec.script_id,
      name: exec.script&.name || "脚本#{exec.script_id}",
      status: status,
      status_text: script_status_text(status),
      conclusion: conclusion_of(result),
      output: devlog_content(exec) || exec.logs,
      error: exec.error_message,
      started_at: exec.started_at&.iso8601,
      completed_at: exec.finished_at&.iso8601,
      duration: human_duration(exec.started_at, exec.finished_at),
      checkpoints: checkpoints,
      checkpoints_total: checkpoints.size,
      checkpoints_passed: checkpoints.count { |cp| cp[:passed] == true },
      checkpoints_failed: checkpoints.count { |cp| cp[:passed] == false }
    }
  end

  # 优先读运行日志文件（客户端 ScriptExecutor 写的完整 devlog.txt）；DB 里的被截断到 1 万字
  def devlog_content(exec)
    return nil unless @run&.started_at && exec.network_element && exec.script

    dir = "task_#{@task.id}_#{@run.started_at.strftime('%Y%m%d_%H%M%S')}"
    path = FilePathUtils.devlog_file_path(
      dir, exec.network_element.ip_address.to_s, exec.script.name,
      base_logs_dir: Rails.root.join('logs').to_s
    )
    return nil unless File.exist?(path)

    content = File.read(path)
    content.empty? ? nil : content
  rescue StandardError
    nil
  end

  def normalize_checkpoints(list)
    return [] unless list.is_a?(Array)

    list.filter_map do |cp|
      next unless cp.is_a?(Hash)

      pick = ->(key) { cp.key?(key) ? cp[key] : cp[key.to_sym] }
      name = pick.call('name')
      passed = pick.call('passed')
      next if name.nil? && passed.nil?

      { name: name, passed: passed, value: pick.call('value'),
        expected: pick.call('expected'), reason: pick.call('reason') }
    end
  end

  # 脚本展示状态：客户端执行器已给出四态（completed/partial/failed/error/pending/running），直接用
  def display_status(exec, _result)
    exec.status
  end

  def conclusion_of(result)
    return result['conclusion'] if result['conclusion'].present?

    case result['status']
    when 'all_passed' then 'success'
    when 'some_failed' then 'partial'
    when 'error' then 'error'
    end
  end

  # 设备状态：只回答"这台设备跑没跑成"
  def device_status(scripts)
    return 'pending' if scripts.empty?

    statuses = scripts.map { |s| s[:status] }.uniq
    if statuses.include?('running')
      'running'
    elsif statuses.all? { |s| s == 'completed' }
      'completed'
    elsif statuses.include?('completed')
      'partial'
    elsif (statuses & %w[failed error]).any?
      'failed'
    elsif (statuses & %w[partial]).any?
      'partial'
    else
      'pending'
    end
  end

  def calculate_statistics(devices)
    total_devices = devices.size
    total_scripts = devices.sum { |d| d[:scripts_count].to_i }
    success_scripts = devices.sum { |d| d[:scripts_success].to_i }

    all_success = devices.count { |d| d[:scripts_count].to_i.positive? && d[:scripts_success] == d[:scripts_count] }
    partial_success = devices.count do |d|
      count = d[:scripts_count].to_i
      count.positive? && (d[:scripts_success].to_i + d[:scripts_partial].to_i).positive? && d[:scripts_success] < count
    end
    all_failed = devices.count do |d|
      count = d[:scripts_count].to_i
      count.positive? && (d[:scripts_success].to_i + d[:scripts_partial].to_i).zero?
    end

    {
      total_devices: total_devices,
      all_success_devices: all_success,
      partial_success_devices: partial_success,
      all_failed_devices: all_failed,
      total_scripts: total_scripts,
      success_scripts: success_scripts,
      failed_scripts: total_scripts - success_scripts,
      success_rate: total_devices.positive? ? "#{((all_success * 100.0) / total_devices).round(1)}%" : '0%',
      script_success_rate: total_scripts.positive? ? "#{((success_scripts * 100.0) / total_scripts).round(1)}%" : '0%'
    }
  end

  def collect_errors(devices)
    errors = Hash.new { |h, k| h[k] = [] }

    devices.each do |device|
      device[:scripts].each do |script|
        next unless %w[failed error].include?(script[:status])

        error_text = script[:error].to_s.strip
        message = if error_text.present?
                    error_text
                  elsif script[:status] == 'error'
                    '执行异常（脚本未能完成执行）'
                  else
                    '检查点未通过（脚本已跑完，判定未通过）'
                  end
        errors[message] << {
          device_id: device[:id], device_name: device[:name], device_ip: device[:device_ip],
          script_id: script[:id], script_name: script[:name]
        }
      end
    end

    errors.map { |error, items| { error: error, count: items.size, affected_devices: items } }
          .sort_by { |e| -e[:count] }
  end

  def flat_scripts(devices)
    devices.flat_map do |device|
      device[:scripts].map do |script|
        script.merge(device_id: device[:id], device_name: device[:name],
                     device_ip: device[:device_ip], device_model: device[:device_model])
      end
    end
  end

  # ---- 时长/文案 ----

  def device_duration(execs)
    starts = execs.map(&:started_at).compact
    finishes = execs.map(&:finished_at).compact
    return nil if starts.empty? || finishes.empty?

    human_duration(starts.min, finishes.max)
  end

  def human_duration(started_at, completed_at)
    return nil unless started_at && completed_at

    seconds = (completed_at - started_at).to_i
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60
    if hours.positive?
      "#{hours}小时#{minutes}分#{secs}秒"
    elsif minutes.positive?
      "#{minutes}分#{secs}秒"
    else
      "#{secs}秒"
    end
  end

  def execution_status_text(status)
    { 'pending' => '等待中', 'running' => '执行中', 'completed' => '已完成',
      'failed' => '失败', 'cancelled' => '已取消' }[status.to_s] || status.to_s
  end

  def device_status_text(status)
    { 'completed' => '执行完成', 'partial' => '部分成功', 'failed' => '登录失败',
      'running' => '执行中', 'pending' => '待执行' }[status.to_s] || status.to_s
  end

  def script_status_text(status)
    { 'completed' => '成功', 'partial' => '部分通过', 'failed' => '失败', 'error' => '执行异常',
      'running' => '执行中', 'pending' => '待执行', 'cancelled' => '已取消' }[status.to_s] || status.to_s
  end
end

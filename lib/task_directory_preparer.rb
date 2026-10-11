# frozen_string_literal: true

require_relative 'file_path_utils'

# 任务目录准备器
# 单一职责：准备任务执行所需的目录结构
class TaskDirectoryPreparer
  # 准备任务目录结构
  # @param execution [LocalTaskExecution] 执行记录对象
  def prepare(execution)
    root_dir = execution.task_root_dir
    FilePathUtils.ensure_dir_exists(root_dir)

    # 创建完整的目录结构
    units = execution.get_execution_units
    puts "[TaskDirectoryPreparer] units class=#{units.class}, units=#{units.inspect[0..500]}"
    return unless units.is_a?(Hash)

    units.each do |device_id, device_info|
      puts "[TaskDirectoryPreparer] Processing device #{device_id}, info class=#{device_info.class}"
      next unless device_info.is_a?(Hash)

      device_ip = device_info['device_ip'] || device_info[:device_ip] || device_id
      scripts = device_info['scripts'] || device_info[:scripts] || {}

      # 确保登录日志目录存在
      login_log_path = device_info['login_log_path'] || device_info[:login_log_path]
      if login_log_path
        FilePathUtils.ensure_file_dir_exists(login_log_path)
      else
        # 如果没有预先生成路径，则生成并确保目录存在
        login_log_path = FilePathUtils.login_log_file_path(execution.task_dir_name, device_ip)
        FilePathUtils.ensure_file_dir_exists(login_log_path)
      end

      # 确保脚本日志目录存在
      next unless scripts.is_a?(Hash)

      scripts.each do |script_id, script_info|
        next unless script_info.is_a?(Hash)

        script_name = script_info['script_name'] || script_info[:script_name] ||
                      script_info['name'] || script_info[:name] || script_id
        devlog_path = FilePathUtils.devlog_file_path(execution.task_dir_name, device_ip, script_name)
        FilePathUtils.ensure_file_dir_exists(devlog_path)
      end
    end

    # 写入任务信息到文件
    execution.save_status_to_file
  end
end

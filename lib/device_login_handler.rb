# frozen_string_literal: true

require_relative 'telnet_device'
require_relative 'file_path_utils'

# 设备登录处理器
# 单一职责：处理设备的登录和连接管理，并记录登录日志
class DeviceLoginHandler
  # 登录设备
  # @param connection_info [Hash] 连接信息
  # @param log_file_path [String, nil] 登录日志文件路径
  # @return [TelnetDevice] 已登录的设备对象
  # @raise [StandardError] 登录失败时抛出异常
  def login(connection_info, log_file_path: nil)
    host = connection_info['host'] || connection_info[:host]
    port = connection_info['port'] || connection_info[:port]
    connection_type = connection_info['connection_type'] || connection_info[:connection_type] || 'telnet'
    username = connection_info['username'] || connection_info[:username]
    password = connection_info['password'] || connection_info[:password]
    enable_command = connection_info['enable_command'] || connection_info[:enable_command]
    enable_password = connection_info['enable_password'] || connection_info[:enable_password]
    root_password = connection_info['root_password'] || connection_info[:root_password]

    log_entries = []
    start_time = Time.now

    add_log_entry(log_entries, 'INFO', "开始登录流程 - 时间: #{start_time.iso8601}")
    add_log_entry(log_entries, 'INFO', "连接信息: 主机=#{host}, 端口=#{port}, 类型=#{connection_type}")

    device = TelnetDevice.new(
      host: host,
      port: port,
      connection_type: connection_type,
      username: username,
      password: password,
      enable_command: enable_command,
      enable_password: enable_password,
      root_password: root_password
    )

    begin
      add_log_entry(log_entries, 'INFO', '正在建立连接...')
      device.login
      
      # 记录登录步骤
      if device.respond_to?(:login_steps) && device.login_steps
        device.login_steps.each do |step|
          add_log_entry(log_entries, 'STEP', step[:step], step[:details])
        end
      end
      
      add_log_entry(log_entries, 'SUCCESS', '设备登录成功')
      device
    rescue => e
      add_log_entry(log_entries, 'ERROR', "登录失败: #{e.class}: #{e.message}")
      add_log_entry(log_entries, 'DEBUG', e.backtrace.join("\n"))
      raise
    ensure
      end_time = Time.now
      duration = (end_time - start_time).round(2)
      add_log_entry(log_entries, 'INFO', "登录流程结束 - 耗时: #{duration}秒")
      
      # 写入日志文件
      write_login_log(log_file_path, log_entries) if log_file_path
    end
  end

  # 关闭设备连接
  # @param device [TelnetDevice] 设备对象
  def close(device)
    device&.close
  end

  private

  # 添加日志条目
  def add_log_entry(entries, level, message, details = nil)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')
    entry = "[#{timestamp}] [#{level}] #{message}"
    entry += "\n  详情: #{details.inspect}" if details
    entries << entry
  end

  # 写入登录日志到文件
  def write_login_log(file_path, entries)
    return if entries.empty?
    
    FilePathUtils.ensure_file_dir_exists(file_path)
    File.open(file_path, 'w:utf-8') do |f|
      f.write(entries.join("\n"))
    end
  end
end

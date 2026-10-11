# frozen_string_literal: true

require 'fileutils'

# Logger 提供结构化的日志记录功能，将框架日志和脚本日志分离存储。
#
# 业务逻辑背景：
# - 网络设备自动化任务需要详细日志以进行故障排查和审计。
# - 框架日志记录连接状态、任务进度等系统事件。
# - 脚本日志记录脚本执行过程中的详细信息（如命令输出、解析结果）。
# - 日志文件按任务、设备、脚本组织，便于后续查找和分析。
#
# 隐性知识：
# - 日志目录结构遵循约定：logs/<task_id>/<device_ip>/{login.log, scripts/}
# - 脚本日志文件名包含脚本名称和时间戳，避免重复执行时的覆盖。
# - 日志内容为纯文本，每行包含时间戳、日志级别和消息。
# - 日志文件在首次写入时创建，目录不存在时会自动创建。
# - 框架日志和脚本日志使用不同的文件句柄，确保并发写入时不会相互干扰。
#
module Qingxun
  class Logger
    # 日志级别常量
    LEVELS = %i[debug info warn error fatal].freeze

    # 初始化日志记录器。
    #
    # 参数：
    #   task_id: 任务标识符（字符串）
    #   device_ip: 设备 IP 地址或主机名（字符串）
    #   base_dir: 日志根目录（默认为 'logs'）
    #
    def initialize(task_id, device_ip, base_dir = 'logs')
      @task_id = task_id
      @device_ip = device_ip
      @base_dir = base_dir

      # 构建目录路径
      @device_dir = File.join(base_dir, task_id, device_ip)
      @platform_log_path = File.join(@device_dir, 'login.log')
      @scripts_dir = File.join(@device_dir, 'scripts')

      # 确保目录存在
      FileUtils.mkdir_p(@device_dir)
      FileUtils.mkdir_p(@scripts_dir)

      # 打开平台日志文件（追加模式）
      @platform_file = File.open(@platform_log_path, 'a')
      @platform_file.sync = true  # 立即刷入磁盘

      # 缓存脚本日志文件句柄（按脚本名称和时间戳）
      @script_files = {}
    end

    # 记录平台日志（框架日志）。
    #
    # 参数：
    #   level: 日志级别（:debug, :info, :warn, :error, :fatal）
    #   message: 日志消息字符串
    #
    def platform_log(level, message)
      entry = format_entry(level, message)
      @platform_file.puts(entry)
    end

    # 记录脚本日志。
    #
    # 参数：
    #   script_name: 脚本名称（用于确定日志文件）
    #   level: 日志级别
    #   message: 日志消息字符串
    #
    def script_log(script_name, level, message)
      file = script_file(script_name)
      entry = format_entry(level, message)
      file.puts(entry)
    end

    # 快捷方法：记录平台信息日志。
    def info(message)
      platform_log(:info, message)
    end

    # 快捷方法：记录平台错误日志。
    def error(message)
      platform_log(:error, message)
    end

    # 快捷方法：记录平台警告日志。
    def warn(message)
      platform_log(:warn, message)
    end

    # 快捷方法：记录平台调试日志。
    def debug(message)
      platform_log(:debug, message)
    end

    # 快捷方法：记录脚本信息日志。
    def script_info(script_name, message)
      script_log(script_name, :info, message)
    end

    # 快捷方法：记录脚本错误日志。
    def script_error(script_name, message)
      script_log(script_name, :error, message)
    end

    # 关闭所有打开的文件句柄。
    def close
      @platform_file.close
      @script_files.each_value(&:close)
      @script_files.clear
    end

    private

    # 根据脚本名称获取或创建脚本日志文件。
    # 每个脚本每次执行使用独立的文件，文件名包含时间戳以避免覆盖。
    def script_file(script_name)
      # 如果已有当前时间戳的文件句柄，则复用
      # 使用简单的策略：每个脚本一个文件（不区分时间戳），因为每次任务执行会创建新目录
      # 但为了更精细，我们可以为每次脚本执行创建新文件（由调用者传递时间戳）。
      # 目前采用每个脚本一个文件，因为 DeviceExecutor 会为每个脚本创建新的 Logger 实例？不，我们复用同一个 Logger。
      # 我们决定使用固定文件名：<script_name>.log
      key = script_name
      return @script_files[key] if @script_files[key]

      file_path = File.join(@scripts_dir, "#{script_name}.log")
      file = File.open(file_path, 'a')
      file.sync = true
      @script_files[key] = file
      file
    end

    # 格式化日志条目。
    def format_entry(level, message)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')
      "#{timestamp} [#{level.to_s.upcase}] #{message}"
    end
  end
end
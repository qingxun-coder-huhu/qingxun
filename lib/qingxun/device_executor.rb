# frozen_string_literal: true

require_relative 'device_script'
require_relative 'connection_factory'
require_relative 'logger'
require_relative 'logging_connection'
require_relative 'sandbox'

# DeviceExecutor 负责单个设备的脚本执行流程。
# 它包括连接建立、顺序执行脚本、日志记录和结果收集。
#
# 业务逻辑背景：
# - 网络设备自动化任务通常需要在多台设备上执行相同的脚本序列。
# - 每台设备的执行相互独立，可以并行进行。
# - 执行过程中需要详细记录登录过程、每个脚本的输出和可能出现的错误。
# - 脚本执行结果需要被收集并返回给上层，用于生成报告或进一步处理。
#
# 隐性知识：
# - 设备连接在脚本执行期间保持打开状态，所有脚本共享同一个连接。
# - 如果某个脚本执行失败（抛出异常），默认会中止该设备的后续脚本执行（但可以配置为继续）。
# - 脚本日志按脚本名称分开存储，便于单独查看。
# - 平台日志记录连接生命周期和脚本执行概览。
# - 执行器会确保连接最终被关闭，即使发生异常。
#
module Qingxun
  class DeviceExecutor
    # 初始化设备执行器。
    #
    # 参数：
    #   device_config: 设备配置哈希（必须包含 host, username, password 等）
    #   script_names: 要执行的脚本名称数组（字符串）
    #   task_id: 任务标识符（用于日志目录组织）
    #   scripts_dir: 脚本文件所在目录（默认为 'scripts'）
    #   logs_dir: 日志根目录（默认为 'logs'）
    #
    def initialize(device_config, script_names, task_id, scripts_dir: 'scripts', logs_dir: 'logs')
      @device_config = device_config
      @script_names = script_names
      @task_id = task_id
      @scripts_dir = scripts_dir
      @logs_dir = logs_dir

      # 从设备配置中提取设备标识（优先使用 host）
      @device_ip = device_config[:host] || 'unknown'
      # 创建日志记录器
      @logger = Logger.new(task_id, @device_ip, logs_dir)
    end

    # 执行设备脚本序列。
    #
    # 返回值：
    #   Hash 包含以下键：
    #     - success: 布尔值，表示整个设备执行是否成功（没有未处理的异常）
    #     - device: 设备标识（IP）
    #     - connection_status: 连接状态（:connected, :failed）
    #     - scripts: 数组，每个元素是包含脚本执行结果的哈希
    #     - error: 如果整体失败，包含错误消息
    #
    # 结构示例：
    #   {
    #     success: true,
    #     device: "192.168.1.1",
    #     connection_status: :connected,
    #     scripts: [
    #       { name: "show_version", success: true, result: { version: "15.2" }, error: nil },
    #       { name: "check_interfaces", success: false, result: nil, error: "超时" }
    #     ]
    #   }
    #
    def execute
      log_info "开始执行设备 #{@device_ip}，脚本列表：#{@script_names.join(', ')}"

      # 连接设备
      connection = connect
      return connection if connection.is_a?(Hash) && connection[:success] == false

      # 顺序执行脚本
      script_results = execute_scripts(connection)

      # 关闭连接
      close_connection(connection)

      # 汇总结果
      {
        success: script_results.all? { |r| r[:success] },
        device: @device_ip,
        connection_status: :connected,
        scripts: script_results,
        error: nil
      }
    rescue => e
      # 捕获未预期的异常（如连接关闭失败）
      log_error "设备 #{@device_ip} 执行过程中发生未预期错误: #{e.class}: #{e.message}"
      {
        success: false,
        device: @device_ip,
        connection_status: :unknown,
        scripts: [],
        error: "#{e.class}: #{e.message}"
      }
    ensure
      @logger.close
    end

    private

    # 连接设备并返回连接对象。
    # 如果连接失败，返回错误结果哈希。
    def connect
      log_info "正在连接设备 #{@device_ip} ..."
      connection = ConnectionFactory.create(@device_config)
      log_info "设备 #{@device_ip} 连接成功，已登录。"
      connection
    rescue => e
      log_error "设备 #{@device_ip} 连接失败: #{e.message}"
      {
        success: false,
        device: @device_ip,
        connection_status: :failed,
        scripts: [],
        error: "连接失败: #{e.message}"
      }
    end

    # 顺序执行所有脚本。
    def execute_scripts(connection)
      @script_names.map do |script_name|
        execute_single_script(script_name, connection)
      end
    end

    # 执行单个脚本。
    def execute_single_script(script_name, connection)
      log_info "开始执行脚本 #{script_name}"
      start_time = Time.now

      # 加载脚本类
      script_class = load_script_class(script_name)
      # 创建脚本专用的日志代理
      script_logger = script_logger_proxy(script_name)
      # 创建脚本实例，传入设备配置和脚本专用的日志代理
      script_instance = script_class.new(@device_config, script_logger)

      # 包装连接以自动记录命令和回显
      wrapped_connection = wrap_connection_with_logging(connection, script_name, script_logger)

      # 创建沙盒并执行脚本
      sandbox = Sandbox.new(script_instance, wrapped_connection, script_logger)
      result = sandbox.run
      elapsed = Time.now - start_time

      log_info "脚本 #{script_name} 执行成功，耗时 #{elapsed.round(2)} 秒"
      {
        name: script_name,
        success: true,
        result: result,
        error: nil,
        elapsed: elapsed
      }
    rescue => e
      elapsed = Time.now - start_time rescue 0
      log_error "脚本 #{script_name} 执行失败: #{e.class}: #{e.message}"
      {
        name: script_name,
        success: false,
        result: nil,
        error: "#{e.class}: #{e.message}",
        elapsed: elapsed
      }
    end

    # 包装连接以自动记录命令和回显。
    def wrap_connection_with_logging(connection, script_name, script_logger)
      # 从设备配置中提取敏感词（密码等）
      sensitive_words = [
        @device_config[:password],
        @device_config[:enable_password]
      ].compact.map(&:to_s).reject(&:empty?)

      LoggingConnection.new(connection, script_logger, script_name, sensitive_words)
    end

    # 加载脚本类。
    def load_script_class(script_name)
      DeviceScript.load_script(script_name, @scripts_dir)
    rescue LoadError => e
      raise "加载脚本 #{script_name} 失败: #{e.message}"
    end

    # 创建一个脚本专用的日志代理对象，将日志转发到主日志记录器的脚本日志通道。
    def script_logger_proxy(script_name)
      # 简单代理，提供与 Logger 相同的接口但固定了脚本名称
      Class.new do
        def initialize(main_logger, script_name)
          @main_logger = main_logger
          @script_name = script_name
        end

        def info(message)
          @main_logger.script_info(@script_name, message)
        end

        def error(message)
          @main_logger.script_error(@script_name, message)
        end

        def warn(message)
          # 如果需要可以扩展
          @main_logger.script_log(@script_name, :warn, message)
        end

        def debug(message)
          @main_logger.script_log(@script_name, :debug, message)
        end
      end.new(@logger, script_name)
    end

    # 关闭设备连接。
    def close_connection(connection)
      log_info "关闭设备 #{@device_ip} 的连接"
      connection.close
    rescue => e
      log_error "关闭连接时发生错误: #{e.message}"
    end

    # 记录平台信息日志。
    def log_info(message)
      @logger.info(message)
    end

    # 记录平台错误日志。
    def log_error(message)
      @logger.error(message)
    end
  end
end
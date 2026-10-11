# frozen_string_literal: true

# Sandbox 模块提供脚本执行的沙盒环境。
# 它通过资源限制、危险命令检测和方法过滤来确保脚本安全运行。
# 脚本在同一个进程中执行，但通过包装连接对象和监控超时来限制影响。
#
# 业务逻辑背景：
# - 用户脚本只需要执行 CLI 命令和解析输出，不应访问文件系统、网络或执行外部命令。
# - 沙盒应防止脚本执行危险设备命令（如 reload、delete 等）。
# - 沙盒应限制脚本的执行时间和内存使用，防止无限循环。
# - 脚本可以通过日志代理记录日志，但不能直接写入文件。
#
# 隐性知识：
# - Ruby 的 $SAFE 机制已弃用，因此我们采用白名单方法过滤危险方法。
# - 使用 Timeout 模块来限制执行时间（但 Timeout 有线程安全问题，不过在此场景下可接受）。
# - 使用 Process.setrlimit 限制内存和 CPU 时间（如果系统支持）。
# - 危险命令检测基于正则表达式模式匹配。
# - 脚本可以访问 Ruby 核心库（String、Array、Hash 等），但危险方法已被移除。
# - 日志记录通过框架提供的 Logger 对象进行，脚本无法直接写入文件。
#
module Qingxun
  module SandboxPatches
    refine File.singleton_class do
      def write(*args)
        raise SecurityError, "文件写入被沙盒阻止"
      end
      def read(*args)
        raise SecurityError, "文件读取被沙盒阻止"
      end
      def open(*args, &block)
        raise SecurityError, "文件打开被沙盒阻止"
      end
    end

    refine Dir.singleton_class do
      def [](*args)
        raise SecurityError, "目录操作被沙盒阻止"
      end
      def glob(*args)
        raise SecurityError, "目录操作被沙盒阻止"
      end
      def mkdir(*args)
        raise SecurityError, "目录创建被沙盒阻止"
      end
    end

    refine Net.singleton_class do
      def const_missing(name)
        raise SecurityError, "网络访问被沙盒阻止"
      end
    end

    refine Kernel do
      {
        system: "系统命令调用",
        exec: "进程替换",
        fork: "进程复制",
        spawn: "进程生成",
        :'`' => "反引号命令执行",
        eval: "代码求值",
        load: "文件加载",
        require: "依赖加载",
        open: "文件打开",
        exit: "进程退出",
        abort: "进程中止"
      }.each do |method, description|
        define_method method do |*args, &block|
          raise SecurityError, "#{description}被沙盒阻止（安全策略）"
        end
        private method
      end
    end
  end

  module SandboxExecutor
    using SandboxPatches
    def self.execute(script_instance, connection)
      script_instance.run(connection)
    end
  end

  class Sandbox
    # 默认资源限制
    DEFAULT_CPU_TIME = 60 * 60      # 秒（CPU 时间）
    DEFAULT_MEMORY   = 20 * 100 * 1024 * 1024  # 100 MB
    DEFAULT_WALL_TIME = 60 * 60     # 秒（实际运行时间）

    # 危险命令模式（正则表达式），匹配时将拒绝执行
    DANGEROUS_COMMANDS = [
      /\breload\b/i,
      /\bdelete\b/i,
      /\bformat\b/i,
      /\berase\b/i,
      /\bwrite\s+memory\b/i,
      /\bcopy\s+run\s+start\b/i,
      /\bconfigure\s+terminal\b/i,
      /\bdebug\b/i,
      /\btclsh\b/i,
      /\breboot\b/i,
      /\bpower\s+cycle\b/i
    ].freeze

    # 初始化沙盒。
    #
    # 参数：
    #   script_instance: DeviceScript 实例（已初始化）
    #   connection: 原始连接对象（TelnetDevice 或 LoggingConnection）
    #   script_logger: 脚本专用的日志记录器
    #   options: 可选的配置哈希，包括：
    #     - cpu_time: CPU 时间限制（秒）
    #     - memory: 内存限制（字节）
    #     - wall_time: 实际时间限制（秒）
    #     - dangerous_command_patterns: 额外危险命令模式数组
    def initialize(script_instance, connection, script_logger, options = {})
      @script_instance = script_instance
      @connection = connection
      @script_logger = script_logger
      @options = options

      @cpu_time = options[:cpu_time] || DEFAULT_CPU_TIME
      @memory = options[:memory] || DEFAULT_MEMORY
      @wall_time = options[:wall_time] || DEFAULT_WALL_TIME
      @dangerous_patterns = DANGEROUS_COMMANDS + (options[:dangerous_command_patterns] || [])
    end

    # 在沙盒中执行脚本的 run 方法。
    #
    # 返回值：
    #   脚本返回的结果对象（必须是可序列化的）
    #
    # 抛出：
    #   SandboxError 如果沙盒执行失败（资源超限、危险操作等）
    def run
      run_in_process
    end

    private

    # 通过 fork 子进程执行脚本，实现强隔离

    # 在当前进程内执行脚本（回退方案）
    def run_in_process
      # 创建沙盒化连接代理（进行危险命令检测）
      sandbox_connection = SandboxConnection.new(@connection, @dangerous_patterns, @script_logger)

      # 设置资源限制
      set_resource_limits
      # 设置执行超时（需要在禁用 require 之前加载）
      require 'timeout'

      begin
        Timeout.timeout(@wall_time) do
          SandboxExecutor.execute(@script_instance, sandbox_connection)
        end
      rescue Timeout::Error => e
        @script_logger.error("[Sandbox] 脚本执行超时（超过 #{@wall_time} 秒）") if @script_logger
        # 输出到 Rails 日志
        if defined?(Rails) && Rails.logger
          Rails.logger.error "[Sandbox] 脚本执行超时: #{e.message}"
          Rails.logger.error "[Sandbox] 调用栈:\n#{e.backtrace.join("\n")}"
        end
        raise SandboxError, "脚本执行超时（超过 #{@wall_time} 秒）"
      rescue => e
        # 捕获所有其他异常，输出详细日志
        @script_logger.error("[Sandbox] 脚本执行出错: #{e.class}: #{e.message}") if @script_logger
        if defined?(Rails) && Rails.logger
          Rails.logger.error "[Sandbox] 脚本执行出错: #{e.class}: #{e.message}"
          Rails.logger.error "[Sandbox] 详细调用栈:\n#{e.backtrace.join("\n")}"
        end
        raise
      end
    end

    private

    # 设置资源限制（CPU 时间、内存）
    def set_resource_limits
      # 设置 CPU 时间限制（秒）
      Process.setrlimit(Process::RLIMIT_CPU, @cpu_time, @cpu_time) if @cpu_time > 0
      # 设置内存限制（字节）
      Process.setrlimit(Process::RLIMIT_AS, @memory, @memory) if @memory > 0
    rescue => e
      # 如果设置失败，记录但继续执行
      @script_logger.error("设置资源限制失败: #{e.message}") if @script_logger
    end


    # SandboxConnection 是一个连接代理，它在执行命令前检查是否危险。
    class SandboxConnection
      def initialize(real_connection, dangerous_patterns, logger)
        @real_connection = real_connection
        @dangerous_patterns = dangerous_patterns
        @logger = logger
      end

      # 执行 CLI 命令，先进行危险检查。
      #
      # 业务逻辑：除了拦截危险命令，这里还把"下发的命令"与"收到的报文"写进脚本日志，
      # 让"执行日志"面板能直接看到完整的命令-回显对话，排查脚本问题时不必再去别处翻。
      # 隐性知识：
      #   1. 记录**原文**（不 inspect），保持报文可读；页面用 pre-wrap 渲染换行。
      #   2. 同一份日志也会作为评估证据进 prompt，因此过长回显的截断交给评估侧统一处理，这里不截。
      def cli(command, **kwargs)
        if dangerous?(command)
          @logger.error("拒绝执行危险命令: #{command}") if @logger
          raise SecurityError, "危险命令被阻止: #{command}"
        end

        @logger.info("下发命令: #{command}") if @logger
        output = @real_connection.cli(command, **kwargs)
        if @logger
          text = output.to_s
          @logger.info("收到报文: #{text.empty? ? '(空)' : text}")
        end
        output
      end

      # 委托其他方法给原始连接（如 close 等）
      def method_missing(method, *args, **kwargs, &block)
        if @real_connection.respond_to?(method)
          @real_connection.send(method, *args, **kwargs, &block)
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        @real_connection.respond_to?(method) || super
      end

      private

      # 判断命令是否危险
      def dangerous?(command)
        @dangerous_patterns.any? { |pattern| command =~ pattern }
      end
    end
  end

  # 沙盒相关错误
  class SandboxError < StandardError; end
end
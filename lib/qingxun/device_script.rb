# frozen_string_literal: true

require 'time'

# DeviceScript 是用户自定义脚本的抽象基类。
# 每个脚本必须继承自 DeviceScript 并实现 `run(connection)` 方法。
# 框架在执行时会创建脚本实例，调用 `run` 方法并传入已连接的设备对象。
#
# 业务逻辑背景：
# - 网络设备自动化通常需要执行一系列命令，并基于输出进行决策。
# - 脚本应专注于业务逻辑，而不必关心连接建立、日志记录等底层细节。
# - 脚本可以返回任意 Ruby 对象作为执行结果，框架会收集这些结果。
#
# 隐性知识：
# - 脚本类名必须与脚本文件名匹配（例如 show_version.rb 中定义 ShowVersion 类）。
# - 脚本不应在 `run` 方法中修改连接对象的状态（如意外关闭连接）。
# - 脚本可以通过 `log_info`、`log_error` 等方法记录日志，这些日志会写入脚本专属日志文件。
# - 脚本可以访问 `@device_config` 哈希，其中包含设备的配置信息（主机、用户名等）。
#
module Qingxun
  # 检查点数据结构
  class Checkpoint
    attr_accessor :name, :passed, :value, :description, :command, :expected, :reason, :suggestion, :timestamp

    def initialize(name:, passed:, value: nil, description: nil, command: nil, expected: nil, reason: nil, suggestion: nil, timestamp: nil)
      @name = name
      @passed = passed
      @value = value
      @description = description
      @command = command
      @expected = expected
      @reason = reason
      @suggestion = suggestion
      @timestamp = timestamp || Time.now
    end

    # 隐性知识（踩过坑）：ActiveSupport 的 `render json:`（内部 `to_json(options)`）会以
    # `as_json(options)` 调用这里（见 active_support/core_ext/object/json.rb），所以
    # **必须接受可选参数**。写成无参 `def as_json` 时，控制器一 render 就抛
    # ArgumentError: wrong number of arguments (given 1, expected 0)。
    def as_json(_options = nil)
      to_h
    end

    # 隐性知识（踩过坑）：标准库 JSON.pretty_generate / JSON.generate **不调用 as_json**，
    # 对象没有 to_json 时会被序列化成 "#<ClassName:0x...>" 字符串，字段全部丢失。
    # 评估 prompt 与页面展示都走 JSON 序列化，因此这里必须显式定义 to_json。
    def to_json(*args)
      to_h.to_json(*args)
    end

    def to_h
      {
        name: name,
        passed: passed,
        value: value,
        description: description,
        command: command,
        expected: expected,
        reason: reason,
        suggestion: suggestion,
        timestamp: timestamp&.iso8601
      }
    end
  end

  # 脚本执行结果
  class ScriptResult
    attr_accessor :success, :status, :error, :summary, :checkpoints, :duration, :started_at, :finished_at

    def initialize(success:, status:, error: nil, summary: {}, checkpoints: [], duration: 0, started_at: nil, finished_at: nil)
      @success = success
      @status = status
      @error = error
      @summary = summary
      @checkpoints = checkpoints
      @duration = duration
      @started_at = started_at
      @finished_at = finished_at
    end

    def all_passed?
      status == "all_passed"
    end

    # 隐性知识（踩过坑）：ActiveSupport 的 `render json:`（内部 `to_json(options)`）会以
    # `as_json(options)` 调用这里（见 active_support/core_ext/object/json.rb），所以
    # **必须接受可选参数**。写成无参 `def as_json` 时，控制器一 render 就抛
    # ArgumentError: wrong number of arguments (given 1, expected 0)。
    def as_json(_options = nil)
      to_h
    end

    # 同 Checkpoint：没有 to_json 时 JSON.generate 会把它变成 "#<...>" 字符串，
    # 评估看不到 summary/checkpoints，页面"返回结果"也会显示成对象地址。
    def to_json(*args)
      to_h.to_json(*args)
    end

    def to_h
      {
        success: success,
        status: status,
        error: error,
        summary: summary,
        checkpoints: checkpoints.map(&:to_h),
        duration: duration,
        started_at: started_at&.iso8601,
        finished_at: finished_at&.iso8601
      }
    end
  end

  class DeviceScript
    class << self
      attr_accessor :integration_dependencies

      def uses_integration(*names)
        @integration_dependencies ||= []
        names.each do |name|
          @integration_dependencies << name.to_sym
          define_method name do
            @_integration_instances ||= {}
            @_integration_instances[name.to_sym] ||= load_integration(name.to_sym)
          end
        end
      end

      def inherited(subclass)
        super
        subclass.integration_dependencies = (@integration_dependencies || []).dup
      end
    end

    attr_accessor :script_user

    # 初始化脚本实例。
    #
    # 参数：
    #   device_config: 设备配置哈希（包含 host, username, password 等）
    #   script_logger: 日志记录器实例，用于输出脚本日志
    #
    def initialize(device_config, script_logger)
      @device_config = device_config
      @logger = script_logger
      @connection = nil
      @checkpoints = []
      @started_at = nil
      @finished_at = nil
    end

    # 设置日志记录器
    def logger=(logger)
      @logger = logger
    end

    # 设置连接对象（也可以通过连接对象记录日志）
    attr_accessor :connection

    # 脚本的主入口点，子类必须实现。
    #
    # 参数：
    #   connection: 已登录的设备连接对象（当前为 TelnetDevice 实例）
    #
    # 返回值：
    #   ScriptResult 对象，通过调用 build_script_result 返回
    #
    def run(connection)
      raise NotImplementedError, "#{self.class} 必须实现 #run 方法"
    end

    # 记录执行开始时间
    def record_start!
      @started_at = Time.now
    end

    # 构建 ScriptResult 对象
    #
    # @param error [Exception, nil] 异常对象（如果有）
    # @return [ScriptResult] 结构化执行结果
    def build_script_result(error = nil)
      @finished_at = Time.now
      @started_at ||= @finished_at
      duration = @finished_at - @started_at

      # 计算状态
      status = if error
                 "error"
               elsif @checkpoints.all? { |cp| cp.passed }
                 "all_passed"
               else
                 "some_failed"
               end

      ScriptResult.new(
        success: error.nil?,
        status: status,
        error: error&.message,
        summary: {
          passed: @checkpoints.count { |cp| cp.passed },
          failed: @checkpoints.count { |cp| cp.passed == false },
          total: @checkpoints.size
        },
        checkpoints: @checkpoints.map(&:to_h),
        duration: duration,
        started_at: @started_at,
        finished_at: @finished_at
      )
    end

    # 记录信息级别日志。
    def log_info(message)
      if @logger
        @logger.info(message)
      elsif @connection && @connection.respond_to?(:log_info)
        @connection.log_info(message)
      end
    end

    # 记录错误级别日志。
    def log_error(message)
      if @logger
        @logger.error(message)
      elsif @connection && @connection.respond_to?(:log_error)
        @connection.log_error(message)
      end
    end

    # 记录警告级别日志。
    def log_warn(message)
      if @logger
        @logger.warn(message)
      elsif @connection && @connection.respond_to?(:log_warn)
        @connection.log_warn(message)
      end
    end

    # 记录调试级别日志。
    def log_debug(message)
      if @logger
        @logger.debug(message)
      elsif @connection && @connection.respond_to?(:log_debug)
        @connection.log_debug(message)
      end
    end

    # 返回设备配置（只读）。
    attr_reader :device_config

    # 返回所有检查点
    attr_reader :checkpoints

    # === 检查点记录方法 ===

    # 记录检查点结果
    #
    # 最简用法:
    #   record_check "检查CPU利用率", cpu < 70
    #
    # 完整用法:
    #   record_check "检查CPU利用率", cpu < 70,
    #     value: cpu,
    #     description: "验证CPU利用率不超过阈值",
    #     command: "display cpu-usage",
    #     expected: "CPU利用率 < 70%",
    #     reason: "CPU过高: #{cpu}%",
    #     suggestion: "检查异常进程"
    #
    def record_check(name, passed, value: nil, **kwargs)
      cp = Checkpoint.new(
        name: name,
        passed: passed,
        value: value,
        description: kwargs[:description],
        command: kwargs[:command],
        expected: kwargs[:expected],
        reason: kwargs[:reason],
        suggestion: kwargs[:suggestion],
        timestamp: Time.now
      )
      @checkpoints << cp
      log_checkpoint_result(cp)
      cp
    end

    private

    # 加载集成实例
    def load_integration(name)
      unless defined?(Qingxun::Integrations)
        require_relative "integrations"
      end

      case name.to_sym
      when :custom
        Qingxun::Integrations::Custom.new(user: script_user, logger: @logger)
      else
        raise "Unknown integration: #{name}"
      end
    end

    # 记录检查点结果日志
    def log_checkpoint_result(cp)
      status = if cp.passed
                 "[通过]"
               elsif cp.passed == false
                 "[失败] #{cp.reason}"
               else
                 "[未完成]"
               end

      log_info("检查点: #{cp.name} - #{status}")
      log_info("  建议: #{cp.suggestion}") if cp.suggestion && cp.passed == false
    end

    # 类方法：根据脚本名称加载脚本类。
    #
    # 业务逻辑：
    #   框架在任务定义中通过字符串（如 "show_version"）引用脚本。
    #   此方法将脚本名称转换为类名（驼峰式），并在预定义的脚本目录中查找对应的 Ruby 文件。
    #   加载文件后，返回相应的类对象。
    #
    # 隐性知识：
    #   脚本目录的路径可通过配置设置，默认为当前工作目录下的 `scripts/`。
    #   脚本文件必须遵循命名约定：小写蛇形命名，类名为驼峰式。
    #   例如脚本 "show_version" 对应文件 `show_version.rb`，其中定义了 `ShowVersion` 类。
    #   如果文件已加载，则避免重复加载（通过 require）。
    #   脚本类可以定义在 Qingxun 模块内，也可以定义在全局命名空间中（不推荐但支持）。
    #
    # 参数：
    #   script_name: 脚本名称（字符串，不含扩展名）
    #   scripts_dir: 脚本目录路径（可选，默认为 'scripts'）
    #
    # 返回：
    #   Class 对象（继承自 DeviceScript）
    #
    # 抛出：
    #   LoadError 如果文件不存在或文件中未定义预期的类。
    def self.load_script(script_name, scripts_dir = 'scripts')
      # 根据文件名推导类名
      # 规则：
      # 1. 如果文件名以大写字母开头（如 ShowVersion_37b179c8），直接作为类名
      # 2. 否则将 snake_case 转换为 CamelCase（如 show_version -> ShowVersion）
      if script_name.match?(/\A[A-Z]/)
        # 新格式：文件名就是类名
        class_name = script_name
      else
        # 旧格式：转换为驼峰式
        class_name = script_name.split('_').map(&:capitalize).join
      end
      
      file_path = File.expand_path(File.join(scripts_dir, "#{script_name}.rb"))

      # 加载文件（每次强制重新加载）
      # 使用 load 加载绝对路径，确保每次加载最新版本
      load file_path

      # 查找类：优先在 QingxunScript 模块中查找，然后在 Qingxun 模块中查找，最后在全局命名空间中查找
      klass = nil
      
      # 尝试加载 QingxunScript 模块（如果存在）
      begin
        require 'qingxun_script' if defined?(QingxunScript).nil?
      rescue LoadError
        # QingxunScript 模块文件不存在，继续其他查找
      end
      
      if defined?(QingxunScript) && QingxunScript.const_defined?(class_name)
        klass = QingxunScript.const_get(class_name)
      elsif Qingxun.const_defined?(class_name)
        klass = Qingxun.const_get(class_name)
      elsif Object.const_defined?(class_name)
        klass = Object.const_get(class_name)
      end
      
      raise LoadError, "脚本 #{script_name} 未定义类 #{class_name}" unless klass

      # 确保该类继承自 DeviceScript（可选检查）
      unless klass <= Qingxun::DeviceScript
        raise LoadError, "脚本类 #{class_name} 必须继承自 Qingxun::DeviceScript"
      end

      klass
    rescue LoadError => e
      raise LoadError, "无法加载脚本 #{script_name}: #{e.message}"
    end
  end
end
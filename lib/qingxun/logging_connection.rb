# frozen_string_literal: true

# LoggingConnection 是一个装饰器，用于包装设备连接对象，自动记录所有 CLI 命令及其回显。
#
# 业务逻辑背景：
# - 网络设备自动化任务需要详细记录下发的命令和设备返回的输出，用于故障排查、审计和事后分析。
# - 命令和回显应该记录到脚本对应的日志文件中，而不是平台日志，以便按脚本组织。
# - 记录的信息应包括命令本身、执行耗时、时间戳以及输出（可能脱敏处理）。
# - 登录和特权模式切换等内部命令已经在平台日志中记录，因此本装饰器仅包装用户脚本通过 `cli` 方法调用的命令。
#
# 隐性知识：
# - 设备连接对象（如 TelnetDevice）必须提供 `cli(command, **kwargs)` 方法。
# - 连接对象可能还提供 `close` 方法，装饰器需透明传递。
# - 脚本日志记录器通过 `DeviceExecutor` 的 `script_logger_proxy` 创建，每个脚本拥有独立的日志通道。
# - 敏感信息（如密码）可能出现在命令字符串或输出中，需要脱敏以避免泄露。
# - 脱敏逻辑基于设备配置中的已知密码字段，简单替换为 "****"。
# - 如果命令执行时间过长，日志记录不应阻塞，因为日志写入是同步的。
# - 装饰器不会修改命令执行逻辑，只增加日志记录副作用。
#
module Qingxun
  class LoggingConnection
    # 初始化装饰器。
    #
    # 参数：
    #   connection: 原始设备连接对象（必须响应 `cli` 和 `close` 方法）
    #   logger: 脚本专用的日志记录器（必须响应 `info` 等方法）
    #   script_name: 脚本名称（用于日志消息标识）
    #   sensitive_words: 敏感词数组，记录时会替换为 "****"（可选）
    def initialize(connection, logger, script_name, sensitive_words = [])
      @connection = connection
      @logger = logger
      @script_name = script_name
      @sensitive_words = sensitive_words.compact.map(&:to_s).reject(&:empty?)
    end

    # 执行 CLI 命令并记录命令与回显。
    #
    # 参数：
    #   command: 命令字符串
    #   **kwargs: 其他参数（如 timeout, match）直接传递给底层连接
    #
    # 返回值：
    #   命令输出字符串（与原始连接返回相同）
    #
    # 日志行为：
    #   1. 记录命令（脱敏后）并附时间戳。
    #   2. 记录命令开始执行的时间。
    #   3. 执行原始连接的 `cli` 方法。
    #   4. 记录命令结束的时间，计算耗时。
    #   5. 记录命令输出（脱敏后）。
    #   6. 如果执行过程中发生异常，记录错误信息后重新抛出。
    def cli(command, **kwargs)
      # 脱敏命令字符串
      logged_command = desensitize(command.dup)
      @logger.info "[#{@script_name}] CMD: #{logged_command}"

      start_time = Time.now
      begin
        output = @connection.cli(command, **kwargs)
      rescue => e
        # 记录异常但不脱敏，因为异常消息通常不包含密码
        @logger.error "[#{@script_name}] 命令执行失败: #{e.class}: #{e.message}"
        raise
      end
      elapsed = Time.now - start_time

    # 脱敏输出字符串
    logged_output = desensitize(output.dup)
    
    # 保留原始的单行摘要日志（向后兼容）
    @logger.info "[#{@script_name}] OUTPUT (耗时 #{elapsed.round(2)}s): #{logged_output[0..500]}#{logged_output.length > 500 ? '...' : ''}"
    
    # 如果输出较长或包含多行，额外记录完整响应
    if logged_output.lines.count > 1 || logged_output.length > 100
      @logger.info "[#{@script_name}] OUTPUT 完整响应开始 ---"
      if logged_output.empty?
        @logger.info "[#{@script_name}] (空响应)"
      else
        # 将输出按行分割，每行单独记录以保持可读性
        logged_output.lines.each do |line|
          line = line.chomp
          @logger.info "[#{@script_name}] #{line}" unless line.empty?
        end
      end
      @logger.info "[#{@script_name}] OUTPUT 完整响应结束 ---"
    end

      output
    end

    # 关闭连接（透明传递）。
    def close
      @connection.close if @connection.respond_to?(:close)
    end

    # 委托其他方法给原始连接（如 `login` 等，但脚本通常不会调用）。
    def method_missing(method, *args, **kwargs, &block)
      if @connection.respond_to?(method)
        @connection.send(method, *args, **kwargs, &block)
      else
        super
      end
    end

    def respond_to_missing?(method, include_private = false)
      @connection.respond_to?(method) || super
    end

    private

    # 脱敏字符串：将敏感词替换为 "****"。
    # 注意：此方法仅进行简单全文替换，不处理部分匹配或上下文。
    # 更复杂的脱敏（如正则表达式匹配密码模式）可以在此扩展。
    def desensitize(str)
      return str if @sensitive_words.empty?

      @sensitive_words.each do |word|
        str = str.gsub(word, '****')
      end
      str
    end
  end
end
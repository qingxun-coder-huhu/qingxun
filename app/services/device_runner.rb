# frozen_string_literal: true

require 'fileutils'
require 'timeout'
require 'json'
require_relative '../../lib/qingxun'

# 在单台真实设备上运行单个脚本。
#
# 流程与线上版的 DebugSession（对模拟设备）一致，区别只在于连接的是真机：
#   1. 把脚本代码写入临时文件，用 Qingxun::DeviceScript.load_script 载入类；
#   2. 用 TelnetDevice 连接设备并登录（支持 telnet / ssh）；
#   3. 在 Qingxun::Sandbox 中执行脚本的 run(connection)，收集日志与返回值；
#   4. 无论成功失败都关闭连接、删除临时文件。
#
# 返回：{ success:, result:, logs:, error:, duration_ms: }
class DeviceRunner
  def initialize(device, script, timeout: nil)
    @device = device
    @script = script
    configured = QingxunConfig.execution[:script_timeout]
    @timeout = (timeout || configured || 300).to_i
  end

  def run
    logs = []
    logger = build_logger(logs)
    started = Time.current
    filepath = nil
    connection = nil

    script_class, filepath = load_script_class(@script.code.to_s)
    connection = build_connection
    connection.login

    instance = script_class.new({ host: @device.ip_address, port: @device.port }, logger)
    sandbox = Qingxun::Sandbox.new(instance, connection, logger)
    result = Timeout.timeout(@timeout) { sandbox.run }

    { success: true, result: jsonable(result), logs: logs,
      duration_ms: elapsed_ms(started) }
  rescue StandardError => e
    { success: false, error: e.message, logs: logs, duration_ms: elapsed_ms(started) }
  ensure
    begin
      connection&.close
    rescue StandardError
      nil
    end
    File.delete(filepath) if filepath && File.exist?(filepath)
  end

  private

  def elapsed_ms(started)
    ((Time.current - started) * 1000).to_i
  end

  # 从代码里取类名 → 写临时文件 → 载入类
  def load_script_class(code)
    match = code.match(/class\s+(\w+)\s*</)
    raise '脚本代码中未找到类定义' unless match

    filename = "#{match[1]}.rb"
    dir = Rails.root.join('tmp', 'execution_scripts')
    FileUtils.mkdir_p(dir)
    filepath = dir.join(filename)
    File.write(filepath, code)

    klass = Qingxun::DeviceScript.load_script(filename.sub('.rb', ''), dir.to_s)
    [klass, filepath]
  end

  def build_connection
    require_relative '../../lib/telnet_device' unless defined?(TelnetDevice)
    TelnetDevice.new(
      host: @device.ip_address,
      port: @device.port,
      connection_type: @device.connection_type,
      username: @device.username,
      password: @device.decrypt_password,
      enable_command: @device.enable_command,
      enable_password: @device.decrypt_enable_password
    )
  end

  # 把日志收集到数组（与 DebugSession 相同的格式化方式）
  def build_logger(logs_array)
    Logger.new(StringIO.new).tap do |logger|
      logger.formatter = proc do |severity, datetime, _progname, msg|
        logs_array << "#{datetime.strftime('%Y-%m-%d %H:%M:%S.%L')} [#{severity}] #{msg}"
        nil
      end
    end
  end

  # 脚本返回值转成可安全落库的 JSON 结构
  def jsonable(result)
    case result
    when Hash, Array, String, Numeric, TrueClass, FalseClass, NilClass
      result.is_a?(Hash) ? JSON.parse(result.to_json) : { value: result }
    else
      JSON.parse(result.to_json)
    end
  rescue StandardError
    { value: result.to_s }
  end
end

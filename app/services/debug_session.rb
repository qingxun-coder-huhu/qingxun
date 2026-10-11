# frozen_string_literal: true

require 'fileutils'
require 'tempfile'
require_relative 'fake_telnet_server_manager'
require_relative '../../lib/qingxun'

# DebugSession 负责在沙盒中执行生成的脚本。
# 它协调 FakeTelnetServerManager、脚本加载和 Qingxun::Sandbox 执行。
#
# 业务逻辑：
#   - 接收生成的 Ruby 代码（字符串）和可选的用户描述。
#   - 启动 FakeTelnetServerManager 获取设备连接参数。
#   - 将代码写入临时文件，并使用 Qingxun::DeviceScript.load_script 加载类。
#   - 创建设备连接（TelnetDevice）并连接到模拟服务器。
#   - 使用 Qingxun::Sandbox 执行脚本，捕获结果和日志。
#   - 返回结构化的执行结果（成功/失败、返回值、日志）。
#
# 隐性知识：
#   - 临时文件需要放在脚本目录（或临时目录）以便 require 能正确加载。
#   - 脚本类名必须符合驼峰命名，且文件名必须与类名匹配（蛇形命名）。
#   - 设备连接使用 TelnetDevice（Qingxun 内部），但框架可能已封装。
#   - 沙盒执行可能因超时、资源限制或危险命令而失败，需要适当处理异常。
class DebugSession
  # 初始化调试会话。
  # 参数：
  #   code: 生成的 Ruby 代码字符串
  #   description: 用户描述（用于动态命令响应，可选）
  #   command_mapping: 命令映射数组（可选）
  #   port: 模拟服务器端口（可选，默认 0 表示随机端口）
  #   user: 当前用户（可选），用于加载自定义集成
  def initialize(code, description = nil, command_mapping = nil, port = 0, user: nil)
    @code = code.to_s.strip
    raise ArgumentError, '代码不能为空' if @code.empty?
    @description = description
    @command_mapping = command_mapping
    @port = port
    @user = user
    @server_manager = nil
    @connection = nil
    @script_class = nil
  end

  # 执行调试会话。
  # 返回哈希：{ success: Boolean, result: Object, logs: Array<String>, error: String }
  def run
    # 1. 启动模拟服务器
    @server_manager = FakeTelnetServerManager.new(
      description: @description, 
      command_mapping: @command_mapping,
      port: @port
    )
    connection_params = @server_manager.start

    # 2. 将代码写入临时文件并加载类
    script_filename, script_class = load_script_class(@code)

    # 3. 创建设备连接（使用 TelnetDevice）
    @connection = create_connection(connection_params)
    # 执行登录
    @connection.login

    # 4. 准备脚本实例和日志收集器
    logs = []
    script_logger = create_logger(logs)
    script_instance = script_class.new(connection_params, script_logger)
    # 设置用户信息，用于自定义集成
    script_instance.script_user = @user if @user && script_instance.respond_to?(:script_user=)

    # 5. 在沙盒中执行
    sandbox = Qingxun::Sandbox.new(script_instance, @connection, script_logger)
    result = sandbox.run

    # 6. 返回成功结果
    {
      success: true,
      result: result,
      logs: logs
    }
  rescue => e
    # 捕获任何异常，输出详细调用栈到日志
    Rails.logger.error "[DebugSession] 脚本执行出错: #{e.class}: #{e.message}"
    Rails.logger.error "[DebugSession] 详细调用栈:\n#{e.backtrace.join("\n")}"

    # 返回错误信息
    {
      success: false,
      error: e.message,
      backtrace: e.backtrace.first(10),
      logs: logs || []
    }
  ensure
    # 7. 清理资源
    @connection&.close if @connection.respond_to?(:close)
    @server_manager&.stop
    # 删除临时文件（如果存在）
    File.delete(script_filename) if script_filename && File.exist?(script_filename)
  end

  private

  # 将代码写入临时文件，加载并返回类。
  # 返回 [临时文件路径, 类对象]
  def load_script_class(code)
    # 从代码中提取类名（简单正则匹配）
    class_name_match = code.match(/class\s+(\w+)\s*</)
    raise '代码中未找到类定义' unless class_name_match
    class_name = class_name_match[1]

    filename = class_name + '.rb'
    
    temp_dir = Rails.root.join('tmp', 'debug_scripts')
    FileUtils.mkdir_p(temp_dir)
    filepath = temp_dir.join(filename)

    # 写入代码
    File.write(filepath, code)

    # 加载脚本类（使用 Qingxun::DeviceScript.load_script）
    script_class = Qingxun::DeviceScript.load_script(filename.sub('.rb', ''), temp_dir.to_s)
    [filepath, script_class]
  end

  # 创建设备连接（TelnetDevice）。
  # 注意：TelnetDevice 可能位于 lib/telnet_device.rb，需要 require。
  def create_connection(params)
    # 由于 TelnetDevice 是现有库的一部分，我们直接实例化它。
    # 如果 TelnetDevice 未加载，则加载它。
    require_relative '../../lib/telnet_device' unless defined?(TelnetDevice)
    TelnetDevice.new(
      host: params[:host],
      port: params[:port],
      username: params[:username],
      password: params[:password],
      enable_command: 'enable',
      enable_password: params[:enable_password]
    )
  end



  # 创建简单的日志记录器，将日志收集到数组中。
  def create_logger(logs_array)
    Logger.new(StringIO.new).tap do |logger|
      logger.formatter = proc do |severity, datetime, progname, msg|
        timestamp = datetime.strftime('%Y-%m-%d %H:%M:%S.%L')
        logs_array << "#{timestamp} [#{severity}] #{msg}"
        nil  # 不实际写入任何东西（因为我们使用 StringIO）
      end
    end
  end
end
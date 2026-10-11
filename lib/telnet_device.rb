require 'net/telnet'
require 'net/ssh'
require 'net/ssh/telnet'
require 'timeout'

# TelnetDevice 类用于管理通过 Telnet 连接的 CLI 设备（如网络交换机、路由器等）。
# 它封装了 Net::Telnet 客户端，提供了登录、执行命令等高级功能，并处理了设备类型、
# 特权模式等网络设备特有的交互逻辑。
#
# 业务逻辑背景：
# 1. 网络设备通常通过 Telnet 提供命令行接口（CLI）。
# 2. 登录流程：先输入用户名，然后密码，接着可能需要进行特权模式切换（例如 Cisco 的 enable）。
# 3. 特权模式命令因设备厂商而异（Cisco: "enable", Huawei: "super", Juniper: "configure"）。
# 4. 执行命令时需要等待设备返回提示符（prompt），提示符通常以 #、>、$ 等字符结尾。
# 5. 超时和匹配模式是确保命令执行可靠性的关键。
#
# 隐性知识：
# - 如果未提供特权模式命令（enable_command），则不会尝试进入特权模式。
# - 匹配模式（match）是一个正则表达式，用于检测命令输出的结束。
# - 默认匹配模式为 /[$%#>]\s*$/，匹配常见的提示符字符。
# - 登录后，如果设置了 enable_command 和 enable_password，会自动尝试进入特权模式。
class TelnetDevice
  # 默认 Telnet 端口
  DEFAULT_PORT = 23
  DEFAULT_SSH_PORT = 22
  # 默认命令执行超时（秒）
  DEFAULT_TIMEOUT = 30
  # 默认提示符匹配正则表达式
  DEFAULT_MATCH = /[$#>]\s*$/

  attr_reader :login_steps

  # 测试设备连接（类方法）
  #
  # 参数：
  #   device: 设备对象（必须响应 ip_address, port, connection_type 等属性）
  #   timeout_seconds: 超时时间（秒），默认 10
  #
  # 返回：
  #   包含 status、protocol、message、login_steps 的哈希
  def self.test_conn(device, timeout_seconds = 600)
    protocol = (device.connection_type || 'telnet').to_s.downcase
    telnet_device = new(
      host: device.ip_address,
      port: device.port,
      connection_type: protocol,
      username: device.username,
      password: device.decrypt_password,
      enable_command: device.enable_command,
      enable_password: device.decrypt_enable_password
    )
    begin
      Timeout.timeout(timeout_seconds) do
        p ''
        telnet_device.login
      end
      { status: 'online', protocol: protocol, message: "#{protocol} 登录成功", login_steps: telnet_device.login_steps }
    rescue Timeout::Error => e
      { status: 'timeout', protocol: protocol, message: '连接超时', login_steps: telnet_device.login_steps }
    rescue Errno::ECONNREFUSED => e
      { status: 'refused', protocol: protocol, message: '连接被拒绝', login_steps: telnet_device.login_steps }
    rescue Errno::EHOSTUNREACH => e
      { status: 'unreachable', protocol: protocol, message: '主机不可达', login_steps: telnet_device.login_steps }
    rescue => e
      { status: 'error', protocol: protocol, message: e.message, login_steps: telnet_device.login_steps }
    ensure
      puts 'close'
      telnet_device.close
      puts 'close done'
    end
  end

  # 初始化一个新的 TelnetDevice 实例。
  #
  # 参数：
  #   host: 设备 IP 地址或主机名
  #   port: 端口，默认 Telnet 为 23，SSH 为 22
  #   connection_type: 连接类型 'telnet' 或 'ssh'，默认 'telnet'
  #   username: 登录用户名
  #   password: 登录密码
  #   enable_command: 进入特权模式的命令（如 "enable"），可选
  #   enable_password: 特权模式密码，可选
  #
  # 示例：
  #   # Telnet 连接
  #   dev = TelnetDevice.new(
  #     host: '192.168.1.1',
  #     username: 'admin',
  #     password: 'secret'
  #   )
  #
  #   # SSH 连接
  #   dev = TelnetDevice.new(
  #     host: '192.168.1.1',
  #     connection_type: 'ssh',
  #     username: 'admin',
  #     password: 'secret'
  #   )
  def initialize(host:, port: nil, connection_type: 'telnet', username:, password:,
                 enable_command: nil, enable_password: nil)
    @host = host
    @connection_type = connection_type.to_s.downcase
    @port = port || (@connection_type == 'ssh' ? DEFAULT_SSH_PORT : DEFAULT_PORT)
    @username = username
    @password = password
    @enable_command = enable_command
    @enable_password = enable_password
    @login_steps = []
    @connection = nil
  end

  # 建立连接并执行登录流程。
  #
  # 业务逻辑：
  # 1. 根据 connection_type 选择 Telnet 或 SSH 连接
  # 2. Telnet: 等待登录提示，发送用户名/密码
  # 3. SSH: 通过 Net::SSH 完成认证，等待提示符
  # 4. 如果设置了 enable_command，尝试进入特权模式
  # 5. 登录成功后，连接进入"已登录"状态
  #
  # 返回值：self，支持链式调用。
  def login
    add_login_step('开始登录流程', {connection_type: @connection_type, host: @host, port: @port})
    if @connection_type == 'ssh'
      login_ssh
    else
      login_telnet
    end

    # 如果设置了特权模式命令，则尝试进入特权模式
    if @enable_command
      enter_enable_mode
    end

    self
  end

  # 关闭连接。
  def close
    @connection&.close
  rescue => e
    nil
  ensure
    @connection = nil
  end

  # 进入特权模式
  def enter_enable_mode
    # 如果特权模式命令为空或仅包含空白字符，则跳过
    return if @enable_command.to_s.strip.empty?
    add_login_step('尝试进入特权模式', {enable_command: @enable_command})

    response = @connection.cmd('String' => @enable_command, 'Match' => Regexp.union(/[Pp]assword:/, DEFAULT_MATCH))
    add_login_step('特权模式命令响应', {response: response})
    
    if response =~ /[Pp]assword:/
      add_login_step('需要特权密码')
      raise '需要特权密码但未提供' if @enable_password.to_s.strip.empty?
      enable_response = @connection.cmd('String' => @enable_password, 'Match' => DEFAULT_MATCH)
      add_login_step('已发送特权密码')
      add_login_step('进入特权模式成功', {response: enable_response})
    else
      add_login_step('进入特权模式成功', {response: response})
    end
  end

  # 在设备上执行 CLI 命令。
  #
  # 参数：
  #   command: 要执行的命令字符串
  #   timeout: 命令执行超时时间（秒），可选，默认 DEFAULT_TIMEOUT
  #   match: 用于检测命令结束的正则表达式，可选，默认 DEFAULT_MATCH
  #
  # 返回值：命令输出（已处理退格符）
  def cli(command, timeout: DEFAULT_TIMEOUT, match: DEFAULT_MATCH)
    raise '未连接。请先调用 login 方法。' unless @connection

    puts "[TelnetDevice#cli] 发送命令: #{command.inspect}"
    @connection.puts(command)

    more_pattern = /--More--/
    combined_pattern = Regexp.union(more_pattern, match)

    full_output = ''
    loop do
      puts "[TelnetDevice#cli] 等待匹配模式: #{combined_pattern}"
      chunk = @connection.waitfor('Match' => combined_pattern, 'Timeout' => timeout)
      puts "[TelnetDevice#cli] 收到响应块: #{chunk.inspect}"
      full_output << chunk

      if chunk =~ more_pattern
        puts "[TelnetDevice#cli] 检测到 --More--，发送空格继续"
        @connection.puts(' ')
      else
        puts "[TelnetDevice#cli] 匹配到提示符，命令完成"
        break
      end
    end

    result = apply_backspace(full_output)
    result.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
  end

  private

  # 添加登录步骤
  def add_login_step(step, details = nil)
    @login_steps << { 
      timestamp: Time.now.strftime('%Y-%m-%d %H:%M:%S.%L'),
      step: step,
      details: details 
    }
  end

  # Telnet 登录流程
  def login_telnet
    @connection = Net::Telnet.new(
      'Host' => @host,
      'Port' => @port,
      'Timeout' => DEFAULT_TIMEOUT,
      'Prompt' => DEFAULT_MATCH
    )
    add_login_step('开始Telnet连接', {host: @host, port: @port})

    # 等待用户名提示符（Username: 或 login:）
    username_prompt = @connection.waitfor('Match' => /[Uu]sername:|[Ll]ogin:/)
    add_login_step('收到用户名提示符', {prompt: username_prompt})
    @connection.puts(@username)
    add_login_step('已发送用户名', {username: @username})
    # 等待密码提示符（Password:）
    password_prompt = @connection.waitfor('Match' => /[Pp]assword:/)
    add_login_step('收到密码提示符', {prompt: password_prompt})
    @connection.puts(@password)
    add_login_step('已发送密码')

    # 检查登录是否成功
    error_pattern = /error|login incorrect|authentication failed|invalid|denied|fail/i
    combined_pattern = Regexp.union(DEFAULT_MATCH, error_pattern)
    puts "waitfor:#{combined_pattern}"
    response = @connection.waitfor('Match' => combined_pattern)
    puts "response:#{response}"
    if response =~ error_pattern
      @connection.close rescue nil
      @connection = nil
      add_login_step('登录失败', {error: response})
      raise "Telnet 登录失败: #{response}"
    end
    add_login_step('登录成功', {response: response})
    puts "login ok"
  end

  # SSH 登录流程
  def login_ssh
    @connection = Net::SSH::Telnet.new(
      "Host" => @host,
      "Username" => @username,
      "Password" => @password,
      "Prompt" => DEFAULT_MATCH,
      "Waittime" => 0.2
    )
    add_login_step('开始SSH连接', {host: @host, port: @port, username: @username})
    add_login_step('SSH登录成功')
  rescue => e
    @connection = nil
    add_login_step('SSH登录失败', {error: e.message})
    raise "SSH 登录失败: #{e.message}"
  end

  

  # 按照语义处理退格符（\b）。
  def apply_backspace(output)
    result = []
    output.each_char do |ch|
      if ch == "\b"
        result.pop unless result.empty?
      else
        result << ch
      end
    end
    result.join
  end
end
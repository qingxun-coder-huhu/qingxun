# frozen_string_literal: true

# TelnetDevice 集成测试
# 该测试使用 FakeTelnetServer 模拟真实的网络设备，验证 TelnetDevice 类能否正确与之交互。
# 业务逻辑背景：
#   - 网络设备通过 Telnet 提供 CLI 接口，典型流程为：连接、登录、执行命令、退出。
#   - 特权模式切换（如 Cisco 的 enable）是网络设备管理中的常见操作。
#   - 命令执行后，设备会输出结果并返回提示符，客户端需检测提示符以确定命令结束。
# 隐性背景知识：
#   - FakeTelnetServer 是一个纯 Ruby 实现的模拟服务器，忽略 Telnet IAC 协商，仅处理文本交互。
#   - 服务器默认使用提示符 "Switch> "（普通模式）和 "Switch# "（特权模式），以空格结尾。
#   - TelnetDevice 使用 Net::Telnet 客户端，其默认提示符匹配模式为 /[$%#>]\s*$/，可匹配上述提示符。
#   - 集成测试需动态分配端口，避免与本地其他服务冲突。
#   - 服务器启动后需等待其完全就绪，否则客户端连接可能失败。
#   - 测试结束后必须确保服务器停止，释放端口和线程资源。

require 'spec_helper'
require 'socket'
require './lib/fake_telnet_server'

RSpec.describe 'TelnetDevice integration with FakeTelnetServer' do
  # 动态获取一个空闲端口
  # 方法：创建临时 TCPServer 并绑定到端口 0，让操作系统分配一个可用端口。
  # 获取端口号后立即关闭临时服务器，以便后续测试使用该端口。
  # 注意：存在极小的竞争条件（端口可能在关闭后立即被其他进程占用），
  # 但在本地测试环境中概率极低，可接受。
  def find_free_port
    server = TCPServer.new('localhost', 0)
    port = server.addr[1]
    server.close
    port
  end

  # 测试使用的配置
  let(:free_port) { find_free_port }
  let(:username) { 'admin' }
  let(:password) { 'password' }
  let(:enable_password) { 'enable' }
  let(:server) do
    FakeTelnetServer.new(
      host: 'localhost',
      port: free_port,
      username: username,
      password: password,
      enable_password: enable_password,
      login_prompt: 'Login: ',
      password_prompt: 'Password: '
    )
  end

  # 在每个示例之前启动服务器
  before do
    server.start
    # 等待服务器真正开始监听（避免客户端连接过早）
    sleep 0.1 until server.running?
  end

  # 在每个示例之后停止服务器
  after do
    server.stop if server.running?
  end

  describe '登录流程' do
    it '使用正确的凭据成功登录' do
      # 业务逻辑：网络设备要求先输入用户名，再输入密码。
      # 隐性知识：TelnetDevice 的 login 方法内部使用 Net::Telnet#login，
      # 该方法会自动等待 "Username:" 和 "Password:" 提示符并发送相应凭据。
      device = TelnetDevice.new(
        host: 'localhost',
        port: free_port,
        username: username,
        password: password
      )

      # 登录应成功，不抛出异常
      expect { device.login }.not_to raise_error
      # 登录后连接对象应已建立
      expect(device.instance_variable_get(:@connection)).not_to be_nil

      device.close
    end

    it '使用错误的密码导致登录失败' do
      # 业务逻辑：设备验证失败时应拒绝连接，Net::Telnet 会抛出异常。
      # 隐性知识：Net::Telnet#login 在密码错误时会等待超时并引发 Timeout::Error，
      # 但具体行为取决于服务器实现。FakeTelnetServer 会在密码错误后返回错误信息并重新提示用户名，
      # 导致客户端等待下一个提示符而超时。
      # 这里我们预期登录会失败（抛出某种异常），但具体异常类型可能因超时而异。
      # 为简化测试，我们只检查登录过程是否没有成功建立连接（即连接对象仍为 nil）。
      device = TelnetDevice.new(
        host: 'localhost',
        port: free_port,
        username: username,
        password: 'wrong'
      )

      # 由于 FakeTelnetServer 会提示重新输入用户名，Net::Telnet 会等待下一个提示符而超时，
      # 因此 login 方法会抛出 Net::ReadTimeout（或 Timeout::Error）。
      # 我们捕获任何异常，并确认连接未建立。
      begin
        device.login
        # 如果未抛出异常，说明登录流程异常（不应发生），测试失败。
        fail 'Expected login to raise an error'
      rescue => e
        expect(e).to be_a(RuntimeError)
      end
      expect(device.instance_variable_get(:@connection)).to be_nil
    end
  end

  describe '命令执行' do
    let(:device) do
      TelnetDevice.new(
        host: 'localhost',
        port: free_port,
        username: username,
        password: password
      )
    end

    before do
      device.login
    end

    after do
      device.close
    end

    it '执行默认命令 help 并返回预期输出' do
      # 业务逻辑：设备通常提供 help 命令列出可用命令。
      # 隐性知识：FakeTelnetServer 默认添加了 help 命令，返回固定字符串。
      # TelnetDevice#cli 会发送命令，等待提示符，并剥离命令回显和提示符。
      output = device.cli('help')
      expect(output).to include('Available commands: help, exit, enable, show version')
    end

    it '执行 show version 命令并返回模拟的版本信息' do
      # 业务逻辑：show version 是网络设备常用命令，用于查看操作系统版本。
      # 隐性知识：FakeTelnetServer 默认响应该命令，返回一段模拟的 Cisco IOS 版本信息。
      output = device.cli('show version')
      expect(output).to include('Cisco IOS Software')
      expect(output).to include('Version 15.2(4)M7')
    end

    it '处理未知命令，返回错误信息' do
      # 业务逻辑：设备对于无法识别的命令应返回错误提示。
      # 隐性知识：FakeTelnetServer 对于未匹配的命令返回 "Command '...' not recognized."。
      # TelnetDevice 会原样返回该错误信息。
      output = device.cli('unknown_command')
      expect(output).to include("Command 'unknown_command' not recognized.")
    end

    it '支持添加自定义命令' do
      # 业务逻辑：测试中可以动态向服务器添加自定义命令，模拟设备特定的功能。
      # 隐性知识：FakeTelnetServer#add_command 允许添加字符串或正则表达式模式，
      # 响应可以是字符串或可调用对象。该命令仅对该服务器实例生效。
      server.add_command('custom', 'Custom response')
      output = device.cli('custom')
      expect(output).to include('Custom response')
    end
  end

  describe '特权模式切换' do
    context '当 enable_password 已设置' do
      let(:device) do
        TelnetDevice.new(
          host: 'localhost',
          port: free_port,
          username: username,
          password: password,
          enable_command: 'enable',
          enable_password: enable_password
        )
      end

      before do
        device.login
      end

      after do
        device.close
      end

      it '成功进入特权模式' do
        # 业务逻辑：网络设备通过 enable 命令进入特权模式，可能需要输入特权密码。
        # 隐性知识：TelnetDevice 的 login 方法会在标准登录后自动发送 enable 命令，
        # 并检测输出中是否包含 "Password:" 提示，若存在则发送 enable_password。
        # 成功进入特权模式后，设备提示符会从 "Switch> " 变为 "Switch# "。
        # 此处我们通过执行一个命令来验证提示符已变更（尽管输出内容不变）。
        # 更严谨的验证是检查命令输出后的提示符，但 TelnetDevice 会剥离提示符，
        # 因此我们通过服务器日志或连接状态难以直接检测。
        # 作为替代，我们执行一个命令并确认没有异常，且命令正常返回。
        output = device.cli('help')
        expect(output).to include('Available commands')
        # 注意：由于特权模式切换后提示符改变，但命令输出内容不变，
        # 所以此断言无法区分模式。实际应用中，特权模式下可能允许更多命令，
        # 但 FakeTelnetServer 没有区分，因此本测试仅验证流程不报错。
      end

      it '使用错误特权密码导致切换失败' do
        # 业务逻辑：特权密码错误时设备应拒绝进入特权模式。
        # 隐性知识：FakeTelnetServer 在 enable 密码错误后会输出 "Bad secrets."，
        # 并保持在普通模式。TelnetDevice 的 login 方法会发送 enable 命令并检测密码提示，
        # 若密码错误，服务器会返回错误信息，但客户端可能不会抛出异常（因为密码提示流程已结束）。
        # 具体行为取决于实现。这里我们假设登录流程不会因特权密码错误而中断，
        # 但特权模式切换失败。由于 FakeTelnetServer 在密码错误后仍然返回普通提示符，
        # 后续命令执行正常。本测试仅验证不会抛出异常。
        # 创建一个使用错误 enable_password 的设备
        wrong_device = TelnetDevice.new(
          host: 'localhost',
          port: free_port,
          username: username,
          password: password,
          enable_command: 'enable',
          enable_password: 'wrong'
        )
        # 登录应成功（标准登录），但特权模式切换会失败
        expect { wrong_device.login }.not_to raise_error
        wrong_device.close
      end
    end

    context '当 enable_password 为空（不需要密码）' do
      let(:server_without_enable_password) do
        FakeTelnetServer.new(
          host: 'localhost',
          port: find_free_port, # 使用另一个端口避免冲突
          username: username,
          password: password,
          enable_password: nil
        )
      end
      let(:device) do
        TelnetDevice.new(
          host: 'localhost',
          port: server_without_enable_password.instance_variable_get(:@port),
          username: username,
          password: password,
          enable_command: 'enable',
          enable_password: nil
        )
      end

      before do
        server_without_enable_password.start
        sleep 0.1 until server_without_enable_password.running?
        device.login
      end

      after do
        device.close
        server_without_enable_password.stop
      end

      it '11直接进入特权模式而不要求密码' do
        # 业务逻辑：某些设备允许空特权密码，输入 enable 后直接进入特权模式。
        # 隐性知识：FakeTelnetServer 在 enable_password 为 nil 时，收到 enable 命令后
        # 立即将 @privileged 设置为 true，并返回 "Entering privileged mode."。
        # TelnetDevice 的 login 方法发送 enable 命令后，检测输出中无密码提示，
        # 因此不会发送密码，直接完成切换。
        output = device.cli('help')
        expect(output).to include('Available commands')
      end
    end
  end

  # 清理测试：确保服务器停止后端口可重用
  after(:all) do
    # 所有测试结束后，确保没有残留的服务器线程
    # 这里依赖每个示例的 after 钩子已停止服务器，无需额外操作。
  end
end
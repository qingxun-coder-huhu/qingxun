# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TelnetDevice do
  # 测试 TelnetDevice 类，该类封装了网络设备的 Telnet 连接和命令执行。
  # 业务逻辑背景：
  # 1. 网络设备通常通过 Telnet 提供命令行接口（CLI）。
  # 2. 登录流程：先输入用户名，然后密码，接着可能需要进行特权模式切换（例如 Cisco 的 enable）。
  # 3. 特权模式命令因设备厂商而异（Cisco: "enable", Huawei: "super", Juniper: "configure"）。
  # 4. 执行命令时需要等待设备返回提示符（prompt），提示符通常以 #、>、$ 等字符结尾。
  # 5. 超时和匹配模式是确保命令执行可靠性的关键。
  #
  # 隐性知识：
  # - 设备类型（device_type）字段仅用于描述，不影响实际连接逻辑。
  # - 如果未提供特权模式命令（enable_command），则不会尝试进入特权模式。
  # - 匹配模式（match）是一个正则表达式，用于检测命令输出的结束。
  # - 默认匹配模式为 /[$%#>]\s*$/，匹配常见的提示符字符。
  # - 登录后，如果设置了 enable_command 和 enable_password，会自动尝试进入特权模式。
  # - 命令输出包含设备回显的命令本身，返回原始输出（包含回显和提示符）。

  let(:host) { '192.168.1.1' }
  let(:port) { 23 }
  let(:username) { 'admin' }
  let(:password) { 'secret' }
  let(:enable_command) { 'enable' }
  let(:enable_password) { 'enablepass' }
  let(:device_type) { 'Cisco' }
  let(:description) { 'Core Switch' }

  # 模拟 Net::Telnet 连接对象
  let(:mock_connection) { double('Net::Telnet') }

  before do
    # 在所有测试中模拟 Net::Telnet.new 返回一个模拟连接对象
    allow(Net::Telnet).to receive(:new).and_return(mock_connection)
    # 允许连接对象响应必要的方法
    allow(mock_connection).to receive(:options).and_return({})
    allow(mock_connection).to receive(:login)
    allow(mock_connection).to receive(:cmd)
    allow(mock_connection).to receive(:close)
  end

  describe '#initialize' do
    it '使用默认端口' do
      device = described_class.new(host: host, username: username, password: password)
      expect(device.instance_variable_get(:@port)).to eq(described_class::DEFAULT_PORT)
    end

    it '允许可选参数缺失' do
      device = described_class.new(host: host, username: username, password: password)
      expect(device.instance_variable_get(:@enable_command)).to be_nil
      expect(device.instance_variable_get(:@enable_password)).to be_nil
      expect(device.instance_variable_get(:@device_type)).to be_nil
      expect(device.instance_variable_get(:@description)).to be_nil
    end
  end

  describe '#login' do
    context '当未设置特权模式命令时' do
      it '建立连接并执行标准登录流程' do
        device = described_class.new(
          host: host,
          username: username,
          password: password
        )

        # 期望 Net::Telnet.new 被调用并返回模拟连接
        expect(Net::Telnet).to receive(:new).with(
          'Host' => host,
          'Port' => described_class::DEFAULT_PORT,
          'Timeout' => described_class::DEFAULT_TIMEOUT,
          'Prompt' => described_class::DEFAULT_MATCH
        ).and_return(mock_connection)

        # 期望在模拟连接上调用自定义登录流程
        expect(mock_connection).to receive(:waitfor).with('Match' => /[Uu]sername:|[Ll]ogin:/)
        expect(mock_connection).to receive(:puts).with(username)
        expect(mock_connection).to receive(:waitfor).with('Match' => /[Pp]assword:/)
        expect(mock_connection).to receive(:puts).with(password)
        # 密码输入后，等待提示符或错误信息
        combined_pattern = Regexp.union(described_class::DEFAULT_MATCH, /error|login incorrect|authentication failed|invalid|denied|fail/i)
        expect(mock_connection).to receive(:waitfor).with('Match' => combined_pattern).and_return("Switch> ")

        # 登录应返回设备自身以支持链式调用
        result = device.login
        expect(result).to be(device)
        expect(device.instance_variable_get(:@connection)).to eq(mock_connection)
      end
    end

    context '当设置了特权模式命令且需要密码时' do
    end

    context '当设置了特权模式命令但不需要密码时' do
    end
  end

  describe '#cli' do
    let(:device) do
      described_class.new(
        host: host,
        username: username,
        password: password
      )
    end

    before do
      # 模拟登录过程，建立连接
      allow(Net::Telnet).to receive(:new).and_return(mock_connection)
      allow(mock_connection).to receive(:waitfor)
      allow(mock_connection).to receive(:puts)
      device.login
    end

    it '执行命令并返回清理后的输出' do
      command = 'show version'
      raw_output = "show version\r\nSome output text# "

      expect(mock_connection).to receive(:puts).with(command)
      # 复用版 cli 用 waitfor 的 block 收集回显（超时才拿得到数据）
      allow(mock_connection).to receive(:waitfor) do |*_args, &blk|
        blk.call(raw_output)
        nil
      end

      expect(device.cli(command)).to include('Some output text')
    end

    it '允许自定义超时和匹配模式' do
      command = 'show interfaces'
      raw_output = "show interfaces\r\nInterface status# "

      allow(mock_connection).to receive(:puts)
      allow(mock_connection).to receive(:waitfor) do |*_args, &blk|
        blk.call(raw_output)
        nil
      end

      expect(device.cli(command, timeout: 10, match: /#/)).to include('Interface status')
    end

    it '在未连接时引发异常' do
      # 创建一个未登录的设备
      unconnected_device = described_class.new(
        host: host,
        username: username,
        password: password
      )

      expect { unconnected_device.cli('show version') }.to raise_error('未连接。请先调用 login 方法。')
    end
  end

  describe '#close' do
    it '关闭连接并将 connection 设置为 nil' do
      device = described_class.new(
        host: host,
        username: username,
        password: password
      )
      allow(Net::Telnet).to receive(:new).and_return(mock_connection)
      allow(mock_connection).to receive(:waitfor)
      allow(mock_connection).to receive(:puts)
      device.login

      expect(mock_connection).to receive(:close)
      device.close
      expect(device.instance_variable_get(:@connection)).to be_nil
    end

    it '在 connection 为 nil 时安全地执行' do
      device = described_class.new(
        host: host,
        username: username,
        password: password
      )
      # 未登录，connection 为 nil
      expect { device.close }.not_to raise_error
      expect(device.instance_variable_get(:@connection)).to be_nil
    end
  end

end
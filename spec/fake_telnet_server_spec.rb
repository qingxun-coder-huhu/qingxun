# frozen_string_literal: false

require 'spec_helper'
require 'socket'
require 'timeout'
require './lib/fake_telnet_server.rb'
require 'pry'
RSpec.describe FakeTelnetServer do
  let(:port) { 2323 }
  let(:username) { 'admin' }
  let(:password) { 'password' }
  let(:enable_password) { 'enable' }
  let(:server) do
    described_class.new(
      port: port,
      username: username,
      password: password,
      enable_password: enable_password
    )
  end

  before do
    server.start
    # 等待服务器启动
    sleep 0.1 until server.running?
  end

  after do
    server.stop if server.running?
  end

  # 辅助方法：建立与服务器的原始 TCP 连接
  def raw_connection
    TCPSocket.new('localhost', port)
  end

  # 辅助方法：读取套接字中的数据直到超时
  def read_until(socket, timeout = 0.1)
    result = String.new
    deadline = Time.now + timeout
    while Time.now < deadline
      # 等待套接字可读，最多剩余超时时间
      remaining = deadline - Time.now
      break if remaining <= 0
      readable, = IO.select([socket], nil, nil, remaining)
      if readable
        begin
          # 读取可用数据
          result << socket.read_nonblock(1024)
        rescue IO::WaitReadable
          # 应该不会发生，因为 select 指示可读
          break
        rescue EOFError
          # 连接关闭
          break
        end
      else
        # 超时
        break
      end
    end
    result
  end

  describe '#start' do
    it '启动服务器并监听指定端口' do
      expect(server.running?).to be true
      # 尝试连接
      socket = raw_connection
      expect(socket).not_to be_nil
      socket.close
    end
  end

  describe '登录流程' do
    it '要求用户名和密码' do
      socket = raw_connection
      # 应收到登录提示
      output = read_until(socket)
      # binding.pry
      expect(output).to include('Username: ')
      # 发送用户名
      socket.puts username
      output = read_until(socket)
      expect(output).to include('Password: ')
      # 发送密码
      socket.puts password
      output = read_until(socket)
      expect(output).to include('Switch> ')
      socket.close
    end

    it '拒绝无效用户名' do
      socket = raw_connection
      read_until(socket) # 丢弃提示符
      socket.puts 'wrong'
      output = read_until(socket)
      expect(output).to include('Invalid username.')
      expect(output).to include('Username: ')
      socket.close
    end

    it '拒绝无效密码' do
      socket = raw_connection
      read_until(socket)
      socket.puts username
      read_until(socket) # 密码提示
      socket.puts 'wrong'
      output = read_until(socket)
      expect(output).to include('Invalid password.')
      expect(output).to include('Username: ')
      socket.close
    end
  end

  describe '命令执行' do
    before do
      @socket = raw_connection
      read_until(@socket)
      @socket.puts username
      read_until(@socket)
      @socket.puts password
      read_until(@socket) # 登录成功，出现提示符
    end

    after do
      @socket.close if @socket && !@socket.closed?
    end

    it '响应默认命令' do
      @socket.puts 'help'
      output = read_until(@socket)
      expect(output).to include('Available commands')
      expect(output).to include('Switch> ')
    end

    it '响应 show version 命令' do
      @socket.puts 'show version'
      output = read_until(@socket)
      expect(output).to include('Cisco IOS Software')
      expect(output).to include('Switch> ')
    end

    it '处理未知命令' do
      @socket.puts 'unknown'
      output = read_until(@socket)
      expect(output).to include("Command 'unknown' not recognized.")
      expect(output).to include('Switch> ')
    end

    it '支持添加自定义命令' do
      server.add_command('custom', 'Custom response')
      @socket.puts 'custom'
      output = read_until(@socket)
      expect(output).to include('Custom response')
      expect(output).to include('Switch> ')
    end

    it '支持正则表达式命令' do
      server.add_command(/^echo (.+)$/, ->(msg) { "You said: #{msg}" })
      @socket.puts 'echo hello'
      output = read_until(@socket)
      expect(output).to include('You said: hello')
      expect(output).to include('Switch> ')
    end

    # 真实设备上"只敲一个回车"会把提示符原样返回，而不是没有响应。
    # 早先 handle_command 对空行直接 return，客户端等不到提示符就会挂到超时。
    it '空命令只返回提示符，不挂起也不报命令不识别' do
      @socket.puts ''   # 只发一个回车
      output = read_until(@socket)
      expect(output).to include('Switch> ')
      expect(output).not_to include('not recognized')
    end
  end

  describe '特权模式切换' do
    before do
      @socket = raw_connection
      read_until(@socket)
      @socket.puts username
      read_until(@socket)
      @socket.puts password
      read_until(@socket) # 登录成功
    end

    after do
      @socket.close if @socket && !@socket.closed?
    end

    context '当 enable_password 已设置' do
      it '要求输入特权密码' do
        @socket.puts 'enable'
        output = read_until(@socket)
        expect(output).to include('Password: ')
        # 发送错误密码
        @socket.puts 'wrong'
        output = read_until(@socket)
        expect(output).to include('Bad secrets.')
        expect(output).to include('Switch> ')
        # 发送正确密码
        @socket.puts 'enable'
        output = read_until(@socket)
        expect(output).to include('Password: ')
        @socket.puts enable_password
        output = read_until(@socket)
        expect(output).to include('Entering privileged mode.')
        expect(output).to include('Switch# ')
      end

      it '正确密码后进入特权模式' do
        @socket.puts 'enable'
        read_until(@socket) # 密码提示
        @socket.puts enable_password
        output = read_until(@socket)
        expect(output).to include('Entering privileged mode.')
        expect(output).to include('Switch# ')
        # 提示符变为特权模式
        @socket.puts 'help'
        output = read_until(@socket)
        expect(output).to include('Switch# ')
      end
    end

    context '当 enable_password 为空' do
      let(:enable_password) { nil }
      it '直接进入特权模式' do
        @socket.puts 'enable'
        output = read_until(@socket)
        expect(output).to include('Entering privileged mode.')
        expect(output).to include('Switch# ')
      end
    end
  end

  describe '退出命令' do
    before do
      @socket = raw_connection
      read_until(@socket)
      @socket.puts username
      read_until(@socket)
      @socket.puts password
      read_until(@socket)
    end

    after do
      @socket.close if @socket && !@socket.closed?
    end

    it '关闭连接' do
      @socket.puts 'exit'
      # 服务器应关闭连接，读取时得到 EOF
      expect { @socket.read_nonblock(1) }.to raise_error
      # 连接已关闭，客户端套接字未关闭但写入端已关闭
      # 不检查写入错误，因为行为可能因操作系统而异
    end
  end

  describe '多客户端连接' do
    it '可以同时处理多个连接' do
      sockets = []
      3.times do
        socket = raw_connection
        sockets << socket
        read_until(socket)
        socket.puts username
        read_until(socket)
        socket.puts password
        read_until(socket)
      end

      sockets.each do |socket|
        socket.puts 'show version'
        output = read_until(socket)
        expect(output).to include('Cisco IOS Software')
      end

      sockets.each(&:close)
    end
  end

  # 报文与提示符必须同一次写入：客户端用 /[$#>]\s*$/ 判断命令结束，
  # 若报文先单独到达且某行以 > 结尾，会被误判为提示符，输出提前返回、后续命令状态错位。
  describe '报文与提示符的发送' do
    it '把命令响应与提示符合并在同一次写入中' do
      server.add_command('show x', "Line one>\nLine two\n")
      Thread.current[:fake_telnet_state] = {
        logged_in: true, privileged: false,
        expect_username: false, expect_password: false, expect_enable_password: false,
        buffer: String.new
      }
      writes = []
      allow(server).to receive(:send_data) { |_client, data| writes << data }

      server.send(:handle_command, double('client'), 'show x')

      expect(writes.size).to eq(1)
      expect(writes.first).to include('Line one>')
      expect(writes.first).to include('Line two')
      expect(writes.first).to end_with('Switch> ')
    ensure
      Thread.current[:fake_telnet_state] = nil
    end
  end

  # 树状命令映射：命中带 children 的命令即进入下一层上下文，同一命令在不同上下文下
  # 可以有不同回显；查找"就近优先、逐级向上兜底到根"；退出层级由 mock.exit_level 声明。
  describe '上下文树' do
    before do
      server.add_command_tree([
        { command: 'show version', response: 'ROOT-VERSION' },
        { command: 'ls', response: 'root-files' },
        { command: 'switch board 1', response: 'Board 1 selected.',
          children: [
            { command: 'ls', response: 'card1  card2' },
            { command: 'cd card2', response: '',
              children: [{ command: 'ls', response: 'port1  port2' }] },
            { command: 'exit', response: '', exit_level: 1 }
          ] },
        { command: 'exit', response: '', exit_level: 0 }
      ])

      @socket = raw_connection
      read_until(@socket)
      @socket.puts username
      read_until(@socket)
      @socket.puts password
      read_until(@socket)
    end

    after do
      @socket.close if @socket && !@socket.closed?
    end

    def run(cmd)
      @socket.puts cmd
      read_until(@socket, 0.2)
    end

    def enter_board1
      run('switch board 1')
    end

    def enter_card2
      enter_board1
      run('cd card2')
    end

    it '同一命令在不同上下文下返回不同回显' do
      expect(run('ls')).to include('root-files')

      enter_board1
      expect(run('ls')).to include('card1  card2')

      enter_card2
      expect(run('ls')).to include('port1  port2')
    end

    it '当前上下文找不到时逐级向上兜底到根（全局命令各层可用）' do
      enter_card2

      expect(run('show version')).to include('ROOT-VERSION')
    end

    # 提示符不能随上下文变化：映射里没有提示符字段（mock.prompt 已删除），
    # 各家设备提示符不同，一旦让映射写死就会污染生成的脚本
    it '提示符不随上下文变化，始终用服务器自身的默认提示符' do
      expect(run('ls')).to include('Switch> ')

      enter_board1
      expect(run('ls')).to include('Switch> ')

      enter_card2
      expect(run('ls')).to include('Switch> ')
    end

    it 'exit_level 为 1 时回到上一层而不是根' do
      enter_card2

      run('exit')
      # 以"回到上一层后的回显"证明层级，而不是靠提示符
      expect(run('ls')).to include('card1  card2')
    end

    it 'exit_level 为 0 时一路回到根' do
      enter_card2
      run('exit')          # card2 -> board1
      run('exit')          # board1 自带 exit_level:1 -> 根

      expect(run('ls')).to include('root-files')
    end

    it '重复进入同一上下文时回到该层，不重复压栈' do
      enter_board1
      run('switch board 1') # 再次进入 board1

      run('exit')           # 只应退回根，而不是留在 board1
      expect(run('ls')).to include('root-files')
    end

    # 兄弟层之间直接切换：进入 2 号单板应该落到根的直接子层，而不是嵌进 1 号里。
    # 若实现是"简单压栈"，这里 exit 一次会退回 1 号（拿到 card1），而不是根。
    it '从一层直接切到兄弟层时不发生嵌套' do
      server.add_command_tree([
        { command: 'switch board 2', response: 'Board 2 selected.',
          children: [
            { command: 'ls', response: 'sfp1  sfp2' },
            { command: 'exit', response: '', exit_level: 1 }
          ] }
      ])

      enter_board1
      run('switch board 2')
      expect(run('ls')).to include('sfp1  sfp2')

      run('exit')
      expect(run('ls')).to include('root-files')
    end

    it '上下文内的未知命令仍走兜底，并保持默认提示符' do
      enter_board1

      output = run('bogus')
      expect(output).to include("Command 'bogus' not recognized.")
      expect(output).to include('Switch> ')
    end
  end
end
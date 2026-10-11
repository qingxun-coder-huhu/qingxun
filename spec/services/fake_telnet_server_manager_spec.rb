# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require_relative '../../app/services/fake_telnet_server_manager'

# 命令映射加载的回归测试
#
# 背景（实测踩过的真问题）：
#   自动生成脚本时，需求里写明 `diagnose` 命令在真实设备上"收到空字符串"，
#   生成的命令映射也确实是 {"command":"diagnose","response":""}。
#   但测试环境当时用 `.present?` 判断 response，空字符串被当成"没配置"整条丢弃，
#   命令没注册进模拟设备，于是回的是兜底的 "Command 'diagnose' not recognized."。
#   测试环境回显与映射、与真实设备都不一致，把脚本生成一路带偏（3 次重试全败）。
#
# 这里用真实的 FakeTelnetServer + TCP 连接把"空响应映射必须生效"钉死。
RSpec.describe FakeTelnetServerManager do
  let(:manager) { described_class.new(port: 0, command_mapping: mapping) }

  after { manager.stop }

  def read_until(socket, timeout = 0.2)
    result = String.new
    deadline = Time.now + timeout
    while Time.now < deadline
      remaining = deadline - Time.now
      break if remaining <= 0

      readable, = IO.select([socket], nil, nil, remaining)
      break unless readable

      begin
        result << socket.read_nonblock(1024)
      rescue IO::WaitReadable
        break
      rescue EOFError
        break
      end
    end
    result
  end

  def login_socket(conn)
    socket = TCPSocket.new(conn[:host], conn[:port])
    read_until(socket)                 # Username:
    socket.puts conn[:username]
    read_until(socket)                 # Password:
    socket.puts conn[:password]
    read_until(socket)                 # Switch>
    socket
  end

  context '当映射的 response 是空字符串' do
    let(:mapping) { [{ command: 'diagnose', response: '' }] }

    it '命令仍被注册：返回提示符，而不是 not recognized' do
      socket = login_socket(manager.start)

      socket.puts 'diagnose'
      output = read_until(socket)

      expect(output).not_to include('not recognized')
      expect(output).to include('Switch> ')
    ensure
      socket&.close
    end
  end

  context '当映射使用字符串键' do
    let(:mapping) { [{ 'command' => 'diagnose', 'response' => '' }] }

    it '同样支持空响应' do
      socket = login_socket(manager.start)

      socket.puts 'diagnose'
      output = read_until(socket)

      expect(output).not_to include('not recognized')
      expect(output).to include('Switch> ')
    ensure
      socket&.close
    end
  end

  context '当映射的 response 非空' do
    let(:mapping) { [{ command: 'show version', response: 'FAKE VERSION 1.0' }] }

    it '正常返回映射内容' do
      socket = login_socket(manager.start)

      socket.puts 'show version'
      output = read_until(socket)

      expect(output).to include('FAKE VERSION 1.0')
      expect(output).to include('Switch> ')
    ensure
      socket&.close
    end
  end

  context '当映射里 response 键缺失' do
    let(:mapping) { [{ command: 'no_response_key' }] }

    it '视为未配置，走兜底 not recognized（不注册）' do
      socket = login_socket(manager.start)

      socket.puts 'no_response_key'
      output = read_until(socket)

      expect(output).to include('not recognized')
    ensure
      socket&.close
    end
  end

  # 树状映射：命中带 children 的命令进入下一层，同一命令在不同上下文下回显不同。
  context '当映射是嵌套的上下文树' do
    let(:mapping) do
      [
        { command: 'ls', response: 'root-files' },
        { command: 'switch board 1', response: 'Board 1 selected.',
          children: [
            { command: 'ls', response: 'card1  card2' },
            { command: 'exit', response: '', mock: { exit_level: 1 } }
          ] }
      ]
    end

    it '进入子树后同名命令返回该层的回显，exit_level 回到上一层' do
      socket = login_socket(manager.start)

      socket.puts 'ls'
      expect(read_until(socket)).to include('root-files')

      socket.puts 'switch board 1'
      output = read_until(socket)
      expect(output).to include('Board 1 selected.')
      # 提示符不随上下文变化，也不会由映射指定（提示符因设备而异，不能固化）
      expect(output).to include('Switch> ')

      socket.puts 'ls'
      expect(read_until(socket)).to include('card1  card2')

      socket.puts 'exit'
      expect(read_until(socket)).to include('Switch> ')
      socket.puts 'ls'
      expect(read_until(socket)).to include('root-files')
    ensure
      socket&.close
    end
  end

  context '当映射使用字符串键并带 children' do
    let(:mapping) do
      [
        { 'command' => 'enter', 'response' => 'entered',
          'children' => [{ 'command' => 'ls', 'response' => 'inner' }] },
        { 'command' => 'ls', 'response' => 'outer' }
      ]
    end

    it '同样支持嵌套' do
      socket = login_socket(manager.start)

      socket.puts 'ls'
      expect(read_until(socket)).to include('outer')

      socket.puts 'enter'
      socket.puts 'ls'
      expect(read_until(socket)).to include('inner')
    ensure
      socket&.close
    end
  end

  context '当子节点的 response 键缺失' do
    let(:mapping) do
      [
        { command: 'enter', response: 'entered',
          children: [{ command: 'broken' }, { command: 'ls', response: 'inner' }] }
      ]
    end

    it '只跳过坏子节点，同级其他子节点与父节点仍生效' do
      socket = login_socket(manager.start)

      socket.puts 'enter'
      socket.puts 'ls'
      expect(read_until(socket)).to include('inner')

      socket.puts 'broken'
      expect(read_until(socket)).to include('not recognized')
    ensure
      socket&.close
    end
  end
end

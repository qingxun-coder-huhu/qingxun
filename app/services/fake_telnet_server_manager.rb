# frozen_string_literal: true

require 'json'
require_relative '../../lib/fake_telnet_server'

# FakeTelnetServerManager 负责启动、配置和停止 FakeTelnetServer 实例。
# 每个调试会话应使用独立的服务器实例，避免端口冲突。
#
# 业务逻辑：
#   - 启动服务器在随机端口（或默认端口）上。
#   - 提供连接参数（主机、端口、凭据）供脚本使用。
#   - 会话结束后停止服务器并清理资源。
#
# 隐性知识：
#   - FakeTelnetServer 默认监听 2323 端口，但多个并发调试会话需要不同端口。
#   - 动态命令响应需要从用户描述中提取命令和预期输出，这可以通过大模型辅助生成。
#   - 当前实现使用默认命令（show version, show ip interface brief）作为起点。
class FakeTelnetServerManager
  # 默认连接参数（与 FakeTelnetServer 默认匹配）
  DEFAULT_USERNAME = 'admin'.freeze
  DEFAULT_PASSWORD = 'password'.freeze
  DEFAULT_ENABLE_PASSWORD = 'enable'.freeze
  DEFAULT_HOST = 'localhost'.freeze

  # 初始化管理器。
  # 参数：
  #   options: 可配置选项，如 port（指定端口，若为 0 则随机）、command_mapping（直接的命令映射数组）
  def initialize(options = {})
    @port = options[:port] || 2323  # 默认端口 2323
    @command_mapping = options[:command_mapping]
    @server = nil
    @actual_port = nil
  end

  # 启动服务器并动态配置命令。
  # 返回连接参数哈希 { host:, port:, username:, password:, enable_password: }
  def start
    # 创建服务器实例
    @server = FakeTelnetServer.new(
      host: DEFAULT_HOST,
      port: @port,
      username: DEFAULT_USERNAME,
      password: DEFAULT_PASSWORD,
      enable_password: DEFAULT_ENABLE_PASSWORD
    )
    @server.clear_command
    
    # 加载命令映射文件（如果提供）
    load_command_mapping

    @server.start
    @actual_port = @server.instance_variable_get(:@port)
    {
      host: DEFAULT_HOST,
      port: @actual_port,
      username: DEFAULT_USERNAME,
      password: DEFAULT_PASSWORD,
      enable_password: DEFAULT_ENABLE_PASSWORD
    }
  end

  # 停止服务器。
  def stop
    @server.stop if @server&.running?
  end

  # 返回服务器是否正在运行。
  def running?
    @server&.running? || false
  end

  private

  # 加载命令映射（支持嵌套 children 的上下文树）并注册到模拟服务器。
  #
  # 隐性知识（这里出过真问题）：
  #   response **为空字符串是合法的**——真实设备上有些命令就是无回显（只返回提示符），
  #   需求里也明确写了"收到空字符串"。早先这里用 `.present?` 判断 response，
  #   空字符串被当成"没配置"整条丢弃，命令根本没注册进模拟设备，于是 FakeTelnetServer
  #   落到兜底分支返回 "Command 'x' not recognized."——测试环境回显既不一致于被测映射，
  #   也不一致于真实设备，会把脚本生成带偏（diagnose 就是这么被误判的）。
  #   判据必须是"键是否存在"，而不是"值是否非空"。
  #
  #   同样的判据递归适用于子节点：父节点没配 response 时整条（含子树）跳过，
  #   因为没有 response 的"进入命令"在真机上也不存在。
  def load_command_mapping
    return unless @command_mapping.present? && @command_mapping.is_a?(Array)

    @server.add_command_tree(normalize_nodes(@command_mapping))
  end

  # 递归规范化映射节点为模拟服务器可消费的结构。
  # 兼容 mock 块（仅模拟服务器使用的导航元数据：exit_level / prompt）。
  def normalize_nodes(nodes)
    Array(nodes).filter_map do |cmd|
      next unless cmd.is_a?(Hash)

      command  = field(cmd, :command)
      response = field(cmd, :response)

      # 空命令没有映射意义：真实设备上等价于只敲回车，由 FakeTelnetServer 直接回提示符
      next if command.nil? || command.to_s.empty?
      # 键缺失才算"没配置"；空字符串是合法响应，必须注册
      next if response.nil?

      node = { command: command, response: response }
      mock = field(cmd, :mock)
      node[:exit_level] = field(mock, :exit_level) if mock.is_a?(Hash)

      children = normalize_nodes(field(cmd, :children))
      node[:children] = children if children.any?
      node
    end
  end

  # 兼容 symbol / string 两种键的映射条目
  def field(cmd, key)
    cmd.key?(key) ? cmd[key] : cmd[key.to_s]
  end
end
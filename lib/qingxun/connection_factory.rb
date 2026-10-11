# frozen_string_literal: true

require_relative '../telnet_device'

# ConnectionFactory 负责根据设备配置创建并登录设备连接。
# 目前仅支持 Telnet 协议，未来可扩展支持 SSH 等。
#
# 业务逻辑背景：
# - 网络设备自动化需要与设备建立连接，登录（包括特权模式切换）。
# - 不同设备厂商的登录流程可能略有差异，但基本模式相同：用户名、密码、特权密码。
# - 工厂封装了连接创建和登录的细节，使上层代码无需关心具体协议。
#
# 隐性知识：
# - TelnetDevice 类已处理了分页、退格符等常见设备输出特性。
# - 登录过程可能因网络问题或认证失败而抛出异常，工厂不会重试，由调用者处理。
# - 设备配置哈希中的字段名称必须与 TelnetDevice 的初始化参数匹配（蛇形命名）。
# - 如果未提供端口，默认使用 Telnet 标准端口 23。
# - 如果未提供 enable_command，则不会尝试进入特权模式。
#
module Qingxun
  class ConnectionFactory
    # 默认连接类型（目前只支持 :telnet）
    DEFAULT_PROTOCOL = :telnet

    # 根据设备配置创建并登录设备连接。
    #
    # 参数：
    #   device_config: 设备配置哈希，包含以下键（均为可选，但 host、username、password 通常需要）：
    #     - host: 设备 IP 或主机名（必需）
    #     - port: Telnet 端口（默认 23）
    #     - username: 登录用户名（必需）
    #     - password: 登录密码（必需）
    #     - enable_command: 特权模式命令（如 "enable"）
    #     - enable_password: 特权模式密码
    #     - protocol: 连接协议（目前仅支持 :telnet，可省略）
    #
    # 返回值：
    #   已登录的 TelnetDevice 实例（连接已建立并完成认证）。
    #
    # 抛出：
    #   ArgumentError 如果缺少必需参数。
    #   RuntimeError 如果登录失败（如认证错误、连接超时等）。
    #
    def self.create(device_config)
      protocol = device_config[:protocol] || DEFAULT_PROTOCOL
      case protocol.to_sym
      when :telnet
        create_telnet_connection(device_config)
      else
        raise ArgumentError, "不支持的连接协议: #{protocol}"
      end
    end

    private

    # 创建 Telnet 连接并登录。
    def self.create_telnet_connection(config)
      # 必需参数检查
      required_keys = %i[host username password]
      missing = required_keys.select { |k| config[k].nil? || config[k].to_s.empty? }
      raise ArgumentError, "缺少必需参数: #{missing.join(', ')}" unless missing.empty?

      # 构建 TelnetDevice 参数（只传递已知参数）
      telnet_args = {
        host: config[:host],
        port: config[:port] || 23,
        username: config[:username],
        password: config[:password],
        enable_command: config[:enable_command],
        enable_password: config[:enable_password]
      }.compact

      # 创建连接实例
      connection = TelnetDevice.new(**telnet_args)

      # 执行登录（包括特权模式切换）
      connection.login

      # 返回已登录的连接对象
      connection
    rescue => e
      # 包装异常，提供更多上下文
      raise "创建 Telnet 连接失败 (#{config[:host]}): #{e.message}"
    end
  end
end
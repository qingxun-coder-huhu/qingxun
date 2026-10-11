# frozen_string_literal: true

require 'timeout'
require 'time'
require_relative '../../lib/device_login_handler'
require_relative '../../lib/script_executor'

# 在单台真实设备上运行单个脚本 —— 应用侧的**薄适配层**，本身不含执行逻辑。
#
# 复用客户端的类：
#   - 登录：`DeviceLoginHandler`（lib/device_login_handler.rb）
#   - 执行：`ScriptExecutor`（lib/script_executor.rb，已适配为走 Qingxun::Sandbox）
# 本类只负责：把我们的设备/脚本模型映射成它们要的入参，并把结果整理成本应用统一的形状。
#
# 返回：{ success:, result:, logs:, error:, duration_ms: }
class DeviceRunner
  def initialize(device, script, timeout: nil, user: nil, &on_log)
    @device = device
    @script = script
    @user = user
    @on_log = on_log
    @login_handler = DeviceLoginHandler.new
    @executor = ScriptExecutor.new(on_log: on_log)
    configured = QingxunConfig.execution[:script_timeout]
    @timeout = (timeout || configured || 300).to_i
  end

  def run
    started = Time.current
    connection = nil

    connection = @login_handler.login(connection_params)
    outcome = Timeout.timeout(@timeout) do
      @executor.execute(connection, name: @script.name, code: @script.code.to_s, user: @user)
    end

    {
      success: outcome[:conclusion] != 'error' && outcome[:error].nil?,
      # result 同时带上 ScriptResult（status/checkpoints，报告与状态页要用）和脚本的返回值
      result: merged_result(outcome),
      logs: outcome[:output].to_s,
      error: outcome[:error],
      duration_ms: elapsed_ms(started)
    }
  rescue StandardError => e
    { success: false, error: e.message, logs: '', duration_ms: elapsed_ms(started) }
  ensure
    begin
      @login_handler.close(connection)
    rescue StandardError
      nil
    end
  end

  private

  # 把 ScriptResult（status/checkpoints/summary）与脚本 run 的返回值合并成一个 JSON 友好的 Hash
  def merged_result(outcome)
    result = {}
    if outcome[:script_result]
      parsed = parse_hash(outcome[:script_result])
      result = parsed if parsed
    end
    if outcome[:result].is_a?(Hash)
      result = result.merge(parse_hash(outcome[:result]) || {})
    end
    result
  end

  def parse_hash(value)
    parsed = JSON.parse(value.to_json)
    parsed.is_a?(Hash) ? parsed : nil
  rescue StandardError
    nil
  end

  def elapsed_ms(started)
    ((Time.current - started) * 1000).to_i
  end

  # 供 DeviceLoginHandler 使用的连接信息（普通 Hash，与客户端一致）
  def connection_params
    {
      host: @device.ip_address,
      port: @device.port,
      connection_type: @device.connection_type,
      username: @device.username,
      password: @device.decrypt_password,
      enable_command: @device.enable_command,
      enable_password: @device.decrypt_enable_password,
      root_password: (@device.decrypt_root_password if @device.respond_to?(:decrypt_root_password))
    }
  end
end

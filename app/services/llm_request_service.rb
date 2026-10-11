# frozen_string_literal: true

require 'httparty'
require 'json'

# LlmRequestService - 统一的大模型 API 请求服务
#
# 业务逻辑：
#   - 为所有需要调用大模型的服务提供统一的请求入口
#   - 集中管理 API 认证、错误处理与交互记录
#   - BYOK 模式下使用**用户自带的 Key**，服务端不保存、不落盘、不记日志
#
# 隐性知识：
#   1. **Key 绝不写入任何持久化介质**：不进数据库、不进日志文件、不进 job 参数、
#      不进异常消息。用户 Key 只在一次请求的内存里存活。
#   2. Key 的解析统一走 LlmApiKey.resolve（见该类注释），本服务不再直接读 ENV。
#   3. 错误信息必须脱敏：只保留 HTTP 状态码与 provider 的结构化错误码，
#      **不回显原始响应体**——异常消息会写进文件日志的 error_message 与用户可见文案。
#
# 使用示例：
#   response = LlmRequestService.call(
#     messages: [{ role: 'user', content: '你好' }],
#     service_name: 'script_generation',
#     step_name: 'generate'
#   )
class LlmRequestService
  # 当 API 响应达到 max_tokens 限制时抛出
  class MaxTokensReachedError < StandardError; end

  # 上游 API 返回非 2xx 时抛出
  #
  # 隐性知识：刻意**不携带响应体**。响应体可能回显请求内容（含认证头），
  # 而本异常的消息会进入数据库与用户可见文案。
  class ApiRequestError < StandardError
    attr_reader :status_code, :provider_code

    def initialize(status_code, provider_code = nil)
      @status_code = status_code
      @provider_code = provider_code

      detail = ["HTTP #{status_code}"]
      detail << "provider_code=#{provider_code}" if provider_code.present?
      super("LLM API 请求失败（#{detail.join(', ')}）")
    end
  end

  DEFAULT_TEMPERATURE = 0
  DEFAULT_MAX_TOKENS = 63000
  DEFAULT_TIMEOUT = 300

  class << self
    # 统一的调用入口
    #
    # 参数:
    #   messages: 消息数组，格式为 [{ role: 'system'|'user'|'assistant', content: '...' }, ...]
    #   service_name: 调用方服务名（用于交互记录），缺省时由调用栈推断
    #   step_name: 步骤名（用于交互记录）
    #   request_context: 请求上下文，缺省时取线程局部的 user_request_context
    #   api_key: 显式指定 Key；缺省时由 LlmApiKey.resolve 解析（请求级 → 平台兜底）
    #   model / api_url: 覆盖默认模型与端点
    #
    # 返回:
    #   API 响应的解析哈希
    #
    # 抛出:
    #   LlmApiKey::MissingApiKeyError 未提供任何 Key 时
    #   ApiRequestError 上游返回非 2xx 时
    #   MaxTokensReachedError 输出被 max_tokens 截断时
    def call(messages:, service_name: nil, step_name: nil, request_context: nil,
             api_key: nil, model: nil, api_url: nil, max_tokens: nil, temperature: nil)
      resolved = LlmApiKey.resolve_with_source(explicit: api_key)
      api_key = resolved[:key]

      # 端点与模型来自 config/qingxun.yml（见 QingxunConfig）；显式参数可覆盖。
      api_url ||= QingxunConfig.llm_api_url
      model   ||= QingxunConfig.llm_model
      # max_tokens / temperature 可覆盖：入门流程验证 Key 有效性时只需一个最小请求，
      # 沿用默认的 63000 会白白消耗用户额度，也会让验证变慢。
      max_tokens ||= DEFAULT_MAX_TOKENS
      temperature = DEFAULT_TEMPERATURE if temperature.nil?

      headers = {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{api_key}"
      }
      body = {
        model: model,
        messages: messages,
        temperature: temperature,
        max_tokens: max_tokens
      }

      request_context ||= Thread.current[:user_request_context]

      # 文件日志：一次用户请求 = 一个会话目录，目录内每次 LLM 调用一个 JSON。
      # 原先写入 llm_interactions 表的逻辑已移除（见 LlmSessionLogger 的说明）。
      session_log = LlmSessionLogger.start(
        request_context,
        service_name: service_name || caller_service_name,
        step_name: step_name,
        model: model,
        messages: messages
      )

      begin
        start_time = Time.current
        response = send_request(url: api_url, headers: headers, body: body, timeout: DEFAULT_TIMEOUT)
        parsed_response = parse_response(response)

        session_log.success(parsed_response, (Time.current - start_time) * 1000)

        parsed_response
      rescue StandardError => e
        # 失败也要落盘：排查问题时最需要看的正是失败那一次。
        # 只记异常消息（已由 ApiRequestError 保证脱敏），不记响应体。
        session_log.failure(e.message, (Time.current - start_time) * 1000)
        raise e
      ensure
        # 让 Key 尽早离开作用域；调用方若用 LlmApiKey.with 包裹则由其统一清理
        api_key = nil
        headers = nil
      end
    end

    private

    # 发送 HTTP 请求
    #
    # 等上游返回的这段（实测一次生成约 40 秒，上限 DEFAULT_TIMEOUT）不做任何数据库操作，
    # 但连接是被本线程一直占着的：5 个生成就能把连接池（默认 5）占满，第 6 个线程等 5 秒后
    # 拿不到连接直接 500。所以发请求前先归还（详见 ExternalWait）。
    def send_request(url:, headers:, body:, timeout:)
      response = ExternalWait.without_db_connection do
        HTTParty.post(
          url,
          headers: headers,
          body: body.to_json,
          timeout: timeout
        )
      end

      unless response.success?
        # 401/403：多半是 Key 无效或与端点不匹配。把这条最常见的误用直接说清楚，
        # 省得用户对着"HTTP 401"猜。
        if [401, 403].include?(response.code.to_i)
          raise ApiRequestError.new(
            response.code,
            [provider_error_code(response), 'api_key_rejected'].compact_blank.join('/')
          )
        end

        raise ApiRequestError.new(response.code, provider_error_code(response))
      end

      response
    end

    # 从响应体中提取 provider 的结构化错误码
    #
    # 隐性知识：**只取结构化的 type/code 字段，不取自由文本 message**。
    # 自由文本有可能回显请求内容，而结构化字段是受控枚举，可以安全进入日志与数据库。
    def provider_error_code(response)
      parsed = JSON.parse(response.body)
      error = parsed['error']
      return nil unless error.is_a?(Hash)

      [error['type'], error['code']].compact_blank.join('/').presence
    rescue JSON::ParserError, TypeError
      nil
    end

    # 解析响应
    def parse_response(response)
      parsed = JSON.parse(response.body)

      finish_reason = parsed.dig('choices', 0, 'finish_reason')
      if finish_reason == 'length'
        raise MaxTokensReachedError, 'API 响应达到 max_tokens 限制，输出不完整。请简化脚本描述。'
      end

      parsed
    rescue JSON::ParserError
      # 隐性知识（实测踩过）：不仅不能回显原始响应体，**连 JSON::ParserError 的 message 也不能带**——
      # Ruby 的 JSON 解析器会把出错处的片段原样放进 message（形如 "unexpected token at 'not json: sk-xxx'"），
      # 相当于把响应体又泄漏回异常消息里，而异常消息会写进文件日志的 error_message。
      raise "响应解析失败：上游返回的不是合法 JSON" \
            "（原始响应体已省略，长度 #{response.body.to_s.bytesize} 字节）"
    end

    # 由调用栈推断调用方服务名
    def caller_service_name
      caller_locations(3, 1)&.first&.path&.split('/')&.last&.sub('.rb', '') || 'unknown'
    end
  end
end

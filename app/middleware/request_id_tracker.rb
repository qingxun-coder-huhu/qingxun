# frozen_string_literal: true

# 请求ID跟踪中间件
# 为每个请求生成唯一ID，并存储请求上下文到Thread.current
class RequestIdTracker
  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new(env)

    # 生成请求ID
    request_id = SecureRandom.uuid

    # 存储到env，便于在日志中显示
    env['request_id'] = request_id

    # 提取请求上下文
    request_context = extract_request_context(request, request_id)

    # 存储到Thread.current，便于服务层访问
    Thread.current[:user_request_context] = request_context

    # 继续处理请求
    @app.call(env)
  ensure
    # 清理Thread.current，避免内存泄漏
    Thread.current[:user_request_context] = nil
    # 同时清掉 LLM 日志按 request_id 缓存的会话目录与序号（Puma 线程会被复用）
    Thread.current[:llm_session_dirs] = nil
    Thread.current[:llm_session_seq] = nil
  end

  private

  # 提取请求上下文
  def extract_request_context(request, request_id)
    context = {
      request_id: request_id,
      user_id: nil,
      request_type: nil,
      original_input: nil,
      path: request.path,
      method: request.method,
      ip: request.remote_ip,
      user_agent: request.user_agent
    }

    # 尝试获取用户ID
    context[:user_id] = extract_user_id(request)

    # 确定请求类型
    context[:request_type] = determine_request_type(request)

    # 提取原始输入（对于API请求）
    context[:original_input] = extract_original_input(request)

    context
  end

  # 提取用户ID
  def extract_user_id(request)
    # 尝试从会话中获取（Web请求）
    if request.session && request.session[:user_id]
      return request.session[:user_id]
    end

    # 尝试从JWT令牌中获取（API请求）
    auth_header = request.headers['Authorization']
    if auth_header.present? && auth_header.start_with?('Bearer ')
      token = auth_header.split(' ').last
      begin
        payload = JwtService.decode(token)
        return payload[:user_id] if payload
      rescue => e
        Rails.logger.debug "无法从JWT令牌提取用户ID: #{e.message}"
      end
    end

    # 尝试从当前用户对象获取
    if request.env['warden'] && request.env['warden'].user
      return request.env['warden'].user.id
    end

    nil
  end

  # 确定请求类型
  def determine_request_type(request)
    path = request.path

    case path
    when /\/api\/v1\/tasks\/create_from_natural_language/
      'natural_language'
    when /\/scripts\/(generate|auto_generate)/
      'script_generation'
    when /\/api\/v1\//
      'api'
    else
      'web'
    end
  end

  # 提取原始输入
  def extract_original_input(request)
    # 对于JSON请求，尝试提取自然语言输入
    if request.content_type == 'application/json' && request.body.present?
      begin
        body = JSON.parse(request.body.read)
        request.body.rewind # 重置body指针，以便后续读取

        # 根据常见字段名提取输入
        input_fields = ['natural_language', 'description', 'input', 'prompt', 'content']
        input_fields.each do |field|
          return body[field] if body[field].present?
        end

        # 如果找不到特定字段，返回整个body（限制长度）
        return body.to_json[0..500]
      rescue => e
        Rails.logger.debug "无法解析请求体: #{e.message}"
      end
    end

    # 对于表单数据
    if request.params.present?
      input_fields = ['natural_language', 'description', 'input', 'prompt', 'content']
      input_fields.each do |field|
        return request.params[field] if request.params[field].present?
      end
    end

    # 默认返回路径
    "#{request.method} #{request.path}"
  end
end
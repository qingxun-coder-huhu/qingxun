# frozen_string_literal: true

# 应用控制器基类（开源版）
#
# 免登录设计：
#   开源版没有账号体系，任何访问都以一个自动创建的「本地操作员」身份运行。
#   业务数据（脚本、任务、设备等）仍挂在 User 上，靠该账号做归属，
#   因此既有的 user_id 外键与 `current_user.scripts` 之类的查询无需改动。
#
# LLM Key 设计：
#   开源版的 Key 只在配置文件（config/qingxun.yml）中维护，正常请求不携带 Key。
#   这里保留一个覆盖点：若请求头显式带了 X-LLM-Api-Key，则临时覆盖配置值
#   （便于多 Key 场景），并在请求结束后必定清除。
class ApplicationController < ActionController::Base
  # CSRF：HTML 请求用 exception，API/JSON 请求用 null_session
  protect_from_forgery with: :exception, prepend: true
  protect_from_forgery with: :null_session, if: -> { request.format.json? || request.xhr? }

  helper_method :current_user, :logged_in?

  # 每个请求开始前确保本地操作员存在（幂等，取自 User.local_operator 缓存）
  before_action :ensure_local_operator

  around_action :with_llm_api_key

  def user_llm_api_key
    request.headers['X-LLM-Api-Key'].presence
  end

  def with_llm_api_key(&block)
    LlmApiKey.with(user_llm_api_key, &block)
  end

  # 把当前请求携带的 LLM Key 从文本中擦除（异常消息可能回显 Key）
  def redact_llm_key(text)
    key = LlmApiKey.current.to_s
    return text if key.empty?

    text.to_s.gsub(key, '[REDACTED]')
  end

  # 缺少 LLM Key 属于可预期的配置问题，不应表现为 500
  rescue_from LlmApiKey::MissingApiKeyError do |e|
    respond_to do |format|
      format.json { render json: { success: false, error: e.message, code: 'missing_llm_api_key' }, status: :bad_request }
      format.html { render plain: e.message, status: :bad_request }
      format.any  { render plain: e.message, status: :bad_request }
    end
  end

  # 当前操作员（开源版唯一）
  def current_user
    @current_user ||= User.local_operator
  end

  def logged_in?
    true
  end

  private

  def ensure_local_operator
    current_user
  end
end

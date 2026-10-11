# Rack::Attack 限流和防滥用配置
#
class Rack::Attack
  # 限流配置（通过环境变量启用/禁用）
  if ENV["ENABLE_RATE_LIMITING"] == "true" || !Rails.env.production?
    # 对所有请求的基础限流
    throttle("req/ip", limit: (ENV["RATE_LIMIT_REQ_PER_MIN"] || 300).to_i, period: 1.minute) do |req|
      req.ip unless req.path.start_with?("/assets")
    end

    # API 登录限流
    throttle("logins/ip", limit: (ENV["RATE_LIMIT_LOGINS_PER_MIN"] || 10).to_i, period: 1.minute) do |req|
      req.ip if req.path == "/api/v1/auth/token" && req.post?
    end

    # API 令牌限流
    throttle("api/ip", limit: (ENV["RATE_LIMIT_API_REQ_PER_MIN"] || 120).to_i, period: 1.minute) do |req|
      req.ip if req.path.start_with?("/api/")
    end

    # 阻止恶意用户代理
    blocklist("block bad bots") do |req|
      bad_user_agents = ENV["BLOCKED_USER_AGENTS"]&.split(",")&.map(&:strip) || []
      bad_user_agents.any? { |agent| req.user_agent&.include?(agent) }
    end
  end

  # 限流响应
  self.throttled_responder = lambda do |request|
    [
      429, # 状态码
      { "Content-Type" => "application/json" }, # 响应头
      [{ error: "请求过于频繁，请稍后再试" }.to_json] # 响应体
    ]
  end
end

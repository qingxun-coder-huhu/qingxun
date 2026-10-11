# frozen_string_literal: true

require 'jwt'

# JWT 服务类
#
# 业务逻辑：
# 提供 JWT 令牌的编码和解码功能，用于 API 认证。
# 使用用户的 API Token 换取短期有效的 JWT 访问令牌。
#
class JwtService
  # JWT 密钥（使用 Rails 的 secret_key_base）
  class << self
    # 编码 JWT 令牌
    #
    # 参数:
    #   user_id: 用户 ID
    #   expires_in: 过期时间（秒），默认 24 小时
    #
    # 返回:
    #   JWT 令牌字符串
    def encode(user_id, expires_in: 24.hours.to_i)
      payload = {
        user_id: user_id,
        exp: Time.current.to_i + expires_in,
        iat: Time.current.to_i
      }
      
      JWT.encode(payload, secret_key, algorithm)
    end
    
    # 解码 JWT 令牌
    #
    # 参数:
    #   token: JWT 令牌字符串
    #
    # 返回:
    #   解码后的 payload 哈希，或 nil 表示无效/过期
    def decode(token)
      decoded = JWT.decode(token, secret_key, true, algorithm: algorithm)
      decoded.first.symbolize_keys
    rescue JWT::ExpiredSignature
      nil
    rescue JWT::DecodeError
      nil
    end
    
    private
    
    def secret_key
      Rails.application.credentials.secret_key_base || Rails.application.secret_key_base
    end
    
    def algorithm
      'HS256'
    end
  end
end

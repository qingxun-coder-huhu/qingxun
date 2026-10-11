# frozen_string_literal: true

# 用户表迁移文件
#
# 业务逻辑：
# 用户表是NetCat系统从单机工具转向SaaS平台的核心基础。
# 支持两种登录方式：
# 1. 邮箱+密码：基础认证方式，使用bcrypt进行密码哈希
# 2. 微信OpenID：为后续微信登录功能预留，微信用户首次登录时创建账号
#
# 隐性知识：
# 1. password_digest字段由has_secure_password自动管理，存储bcrypt哈希值
# 2. 微信登录实现需要额外的OAuth流程，此处仅预留字段
# 3. 用户邮箱需要唯一性约束，但微信OpenID可为空（非微信用户）
# 4. 后续可能需要添加更多字段：用户名、头像、角色权限等
#
class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      # 邮箱地址：用户登录标识，要求唯一性
      # 业务需求：支持邮箱登录，作为主要用户标识
      t.string :email, null: false, index: { unique: true }
      
      # 密码摘要：存储bcrypt哈希后的密码
      # 安全考虑：不存储明文密码，使用ActiveRecord的has_secure_password
      t.string :password_digest, null: false
      
      # 微信OpenID：用于微信登录的标识符
      # 扩展性：预留字段，支持后续微信OAuth集成
      # 注意：微信用户首次登录时创建或关联账号
      t.string :wechat_openid, index: { unique: true }
      
      # 时间戳：记录创建和更新时间
      # Rails惯例：自动管理created_at和updated_at
      t.timestamps
    end
    
    # 添加注释说明表用途（SQLite不支持COMMENT语法，此处为代码注释）
    # 生产环境建议：定期清理未激活用户，添加邮箱验证流程
    # SQLite不支持表注释和列注释，以下为文档说明：
    # 表用途：用户表：存储系统用户信息，支持邮箱密码和微信登录
    # 字段说明：
    #   email - 用户邮箱，登录标识，唯一约束
    #   password_digest - 密码哈希值，使用bcrypt算法
    #   wechat_openid - 微信OpenID，用于微信登录认证
  end
end
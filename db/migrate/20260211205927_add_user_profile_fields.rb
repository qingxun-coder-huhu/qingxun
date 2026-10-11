# frozen_string_literal: true

# 为用户表添加额外字段迁移
#
# 业务逻辑：
# 原始用户迁移仅包含基本字段（邮箱、密码、微信OpenID）。
# 随着SaaS平台功能完善，需要添加以下字段：
# 1. last_login_at: 记录用户最后登录时间，用于安全审计和用户活跃度分析
# 2. last_login_ip: 记录用户最后登录IP地址，用于安全监控和异常登录检测
# 3. activated: 账户激活状态，支持邮件激活流程（预留功能）
# 4. admin: 管理员标识，支持权限分级管理（预留功能）
#
# 安全考虑：
# 1. last_login_ip可用于检测异常登录（如异地登录）
# 2. activated字段支持账户激活流程，防止垃圾注册
# 3. 敏感操作应记录IP地址和时间戳
#
# 隐性知识：
# 1. last_login_at应使用数据库时区存储，查询时转换为用户本地时区
# 2. IP地址应存储为字符串，支持IPv4和IPv6格式
# 3. activated字段默认值为true，确保现有用户不受影响
# 4. admin字段默认值为false，遵循最小权限原则
#
class AddUserProfileFields < ActiveRecord::Migration[7.1]
  def change
    # 添加最后登录时间字段
    # 用途：用户活跃度统计，安全审计，会话管理
    add_column :users, :last_login_at, :datetime, comment: '最后登录时间'
    
    # 添加最后登录IP字段
    # 用途：安全监控，异常登录检测，访问日志
    add_column :users, :last_login_ip, :string, comment: '最后登录IP地址'
    
    # 添加账户激活状态字段
    # 用途：支持邮件激活流程，账户状态管理
    add_column :users, :activated, :boolean, default: true, null: false, comment: '账户是否已激活'
    
    # 添加管理员标识字段
    # 用途：权限分级管理，后台管理功能
    add_column :users, :admin, :boolean, default: false, null: false, comment: '是否为管理员'
    
    # 添加备注字段（预留）
    # 用途：用户备注信息，管理用途
    add_column :users, :notes, :text, comment: '用户备注信息'
  end
end
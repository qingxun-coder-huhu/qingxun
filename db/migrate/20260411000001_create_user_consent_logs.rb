# frozen_string_literal: true

# 创建用户协议同意日志表
#
# 业务逻辑：
# 记录用户同意服务条款和隐私政策的完整审计日志，用于法律合规。
# 只插不删不改：严禁 UPDATE 或 DELETE。用户重新同意或条款更新，直接 INSERT 新记录。
# 历史版本全量保留，形成完整时间轴。
#
# 安全考虑：
# 1. 记录客户端真实IP（注意代理/XFF头）
# 2. 记录浏览器/客户端标识（辅助取证）
# 3. 完整的时间轴记录
# 4. 支持tos和privacy两种协议类型
#
class CreateUserConsentLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :user_consent_logs do |t|
      # 关联用户表ID
      t.string :user_id, null: false, limit: 64

      # 协议类型：'tos'（服务条款）或 'privacy'（隐私政策）
      t.string :agreement_type, null: false, limit: 32

      # 协议版本号，如 '2026-04-08'
      t.string :version, null: false, limit: 16

      # 客户端真实IP（注意代理/XFF头）
      t.string :ip_address, null: false, limit: 45

      # 浏览器/客户端标识（辅助取证）
      t.string :user_agent, limit: 512

      # 勾选动作时间
      t.datetime :consented_at, null: false

      t.timestamps
    end

    # 索引：查询用户的协议同意历史
    add_index :user_consent_logs, [:user_id, :agreement_type, :version],
              name: 'idx_user_type_ver'

    # 索引：按时间查询
    add_index :user_consent_logs, :consented_at,
              name: 'idx_consent_time'

    # 索引：单独查询用户
    add_index :user_consent_logs, :user_id
  end
end

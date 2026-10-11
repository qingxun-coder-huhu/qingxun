# frozen_string_literal: true

# 为客户识别体系（BYOK 免注册）扩展 users 表
#
# 业务逻辑：
#   免注册客户不提供邮箱与密码，仅凭「识别码」证明身份。识别码明文只在生成时
#   返回一次，服务端仅保存其 HMAC 摘要，因此需要放开 email / password_digest 的
#   NOT NULL 约束，并新增识别码摘要与客服存档相关字段。
#
# 隐性知识：
#   1. email 上已存在条件唯一索引（WHERE deactivated_at IS NULL）。放开 NOT NULL 后，
#      多条 email IS NULL 的记录在该索引下不会冲突（PostgreSQL 视 NULL 互不相等）。
#   2. client_code_digest 必须建唯一索引——认证时按摘要直接查找，依赖索引而非全表遍历。
#   3. wechat_id / code_note 是「微信聊天记录即备份」找回流程的客服侧落库字段，
#      用于按微信号反查客户，避免聊天记录成为唯一副本。
class AddClientCodeToUsers < ActiveRecord::Migration[7.1]
  def change
    # 匿名客户没有邮箱和密码
    change_column_null :users, :email, true
    change_column_null :users, :password_digest, true

    add_column :users, :client_code_digest, :string, comment: '识别码的 HMAC 摘要（不可逆，明文不落库）'
    add_column :users, :code_generated_at, :datetime, comment: '识别码生成/重置时间'
    add_column :users, :wechat_id, :string, comment: '客户微信号，用于售后沟通与人工找回'
    add_column :users, :code_note, :text, comment: '识别码找回的人工核验备注（举证与留痕）'

    add_index :users, :client_code_digest, unique: true
  end
end

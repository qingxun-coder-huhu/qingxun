# frozen_string_literal: true

# 清理旧流程（API Token 认证）遗留的字段
#
# 业务逻辑：
#   认证已全面改为「客户识别码」（X-Client-Code），旧的 users.api_token 通道
#   在 auth_controller 中已彻底移除，该字段不再参与任何认证或授权判断。
#
# 隐性知识：
#   1. api_token 上有唯一索引 index_users_on_api_token，PostgreSQL 在 DROP COLUMN 时
#      会自动一并删除其上的索引，无需单独 remove_index。
#   2. api_token_last_used_at 的语义早已是「客户最后一次调用 API 的时间」，
#      与 api_token 无关了，因此重命名为 api_last_used_at 而非删除。
#      注意不要与 users.last_login_at（Web 后台登录时间）混淆。
#   3. down 里必须把索引建回来，否则回滚后唯一性约束丢失。
class RemoveLegacyApiTokenFromUsers < ActiveRecord::Migration[7.1]
  def up
    remove_column :users, :api_token, :string
    rename_column :users, :api_token_last_used_at, :api_last_used_at
  end

  def down
    add_column :users, :api_token, :string
    add_index :users, :api_token, unique: true
    rename_column :users, :api_last_used_at, :api_token_last_used_at
  end
end

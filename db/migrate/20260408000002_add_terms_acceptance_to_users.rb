# frozen_string_literal: true

# 为用户表添加条款同意字段
#
# 业务逻辑：
# 记录用户同意服务条款和隐私政策的时间和版本，用于法律合规。
# 用户注册时记录，条款更新时可以提示用户重新同意。
#
# 安全考虑：
# 1. 记录同意时间作为法律证据
# 2. 记录同意的版本号，便于追溯
# 3. 这些字段只能由系统设置，用户不能直接修改
#
class AddTermsAcceptanceToUsers < ActiveRecord::Migration[7.1]
  def change
    # 服务条款同意时间
    add_column :users, :terms_accepted_at, :datetime, comment: '同意服务条款的时间'

    # 服务条款版本
    add_column :users, :terms_version, :string, comment: '同意的服务条款版本'

    # 隐私政策同意时间
    add_column :users, :privacy_accepted_at, :datetime, comment: '同意隐私政策的时间'

    # 隐私政策版本
    add_column :users, :privacy_version, :string, comment: '同意的隐私政策版本'

    # 添加索引，便于查询未同意的用户
    add_index :users, :terms_accepted_at
    add_index :users, :privacy_accepted_at
  end
end

class CreateDeactivatedUsersArchive < ActiveRecord::Migration[7.1]
  def change
    create_table :deactivated_users_archives do |t|
      # 原始用户ID（仅用于追踪）
      t.integer :original_user_id

      # 核心信息（用于审计）
      t.string :email, null: false
      t.string :subscription_tier, null: false
      t.datetime :registered_at, null: false
      t.datetime :last_login_at
      t.integer :total_scripts_created, default: 0
      t.integer :total_tasks_executed, default: 0

      # 注销信息
      t.datetime :deactivated_at, null: false
      t.string :deactivation_reason
      t.string :deactivated_by, null: false, default: 'user'  # 'user' 或 'admin'

      t.index [:email, :deactivated_at], unique: true
      t.index :deactivated_at
    end
  end
end

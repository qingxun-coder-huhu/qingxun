# frozen_string_literal: true

# 移除整套计费体系：信用点 + 订阅/套餐 + 配额统计字段
#
# 业务逻辑：
#   BYOK 免注册后不再有任何额度/套餐概念——脚本生成用用户自己的 LLM Key，
#   平台不再计量；信用点、订阅套餐、配额计数全部废弃。
#
# 隐性知识：
#   本迁移是**破坏性**的（删表 / 删列），按用户明确要求执行，无需数据兼容。
#   down 直接抛不可逆——这些字段对应的业务已经不存在，无法还原出有意义的数据。
class DropBillingSystem < ActiveRecord::Migration[7.1]
  USERS_COLUMNS = %i[
    subscription_tier trial_ends_at
    monthly_ai_generations monthly_task_executions statistics_month
    monthly_credit_points rolled_credit_points package_credit_points consumed_credit_points
    credits_frozen_at tier_changed_at subscription_ends_at
  ].freeze

  def up
    drop_table :credit_point_transactions, if_exists: true

    USERS_COLUMNS.each do |column|
      remove_column :users, column if column_exists?(:users, column)
    end

    if column_exists?(:deactivated_users_archives, :subscription_tier)
      remove_column :deactivated_users_archives, :subscription_tier
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, '计费体系已整体移除，无法回滚'
  end
end

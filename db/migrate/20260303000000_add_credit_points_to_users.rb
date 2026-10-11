# frozen_string_literal: true

class AddCreditPointsToUsers < ActiveRecord::Migration[7.1]
  def change
    # 信用点系统字段

    # 月度套餐信用点（付费用户每月获得）
    add_column :users, :monthly_credit_points, :integer, default: 0, null: false, comment: '本月套餐信用点'

    # 滚动信用点（上月结转的信用点）
    add_column :users, :rolled_credit_points, :integer, default: 0, null: false, comment: '滚动信用点（上月结转）'

    # 信用点包（购买的额外信用点，永不过期）
    add_column :users, :package_credit_points, :integer, default: 0, null: false, comment: '信用点包（永久有效）'

    # 已消费信用点（本月）
    add_column :users, :consumed_credit_points, :integer, default: 0, null: false, comment: '本月已消费信用点'

    # 信用点冻结状态（取消订阅后冻结）
    add_column :users, :credits_frozen_at, :datetime, comment: '信用点冻结时间'

    # 套餐变更时间（用于月中升级按比例计费）
    add_column :users, :tier_changed_at, :datetime, comment: '套餐变更时间'

    # 索引
    add_index :users, :credits_frozen_at
    add_index :users, :tier_changed_at
  end
end

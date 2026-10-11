# frozen_string_literal: true

class CreateCreditPointTransactions < ActiveRecord::Migration[7.1]
  def change
    create_table :credit_point_transactions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :admin, foreign_key: { to_table: :users }

      # 交易类型
      t.string :transaction_type, null: false  # consume, add, remove, upgrade, downgrade, freeze, unfreeze, monthly_reset

      # 信用点变更详情
      t.integer :monthly_change, default: 0, null: false
      t.integer :rolled_change, default: 0, null: false
      t.integer :package_change, default: 0, null: false

      # 变更后余额
      t.integer :monthly_balance, null: false
      t.integer :rolled_balance, null: false
      t.integer :package_balance, null: false

      # 相关操作信息
      t.string :action_type  # ai_generation, task_execution, etc.
      t.string :reason
      t.text :metadata, default: '{}'  # JSON 字段存储额外信息

      t.timestamps
    end

    add_index :credit_point_transactions, :transaction_type
    add_index :credit_point_transactions, :created_at
  end
end

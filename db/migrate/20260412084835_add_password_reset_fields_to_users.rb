class AddPasswordResetFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :reset_token, :string
    add_column :users, :reset_sent_at, :datetime

    # 添加唯一索引（允许为空）
    add_index :users, :reset_token, unique: true
    # 添加重置发送时间索引用于过期检查
    add_index :users, :reset_sent_at
  end
end

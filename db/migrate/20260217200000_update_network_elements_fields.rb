# frozen_string_literal: true

# 更新网元表字段
#
# 业务逻辑：
# 1. 删除不再需要的 notes 和 public 字段
# 2. 增加 active 字段，与客户端保持一致
#
class UpdateNetworkElementsFields < ActiveRecord::Migration[7.1]
  def change
    # 删除字段
    remove_column :network_elements, :notes, :text if column_exists?(:network_elements, :notes)
    remove_column :network_elements, :public, :boolean if column_exists?(:network_elements, :public)
    
    # 增加 active 字段
    add_column :network_elements, :active, :boolean, default: true, null: false
    
   
  end
end

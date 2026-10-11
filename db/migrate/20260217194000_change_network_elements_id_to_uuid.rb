# frozen_string_literal: true

# 修改网元表主键为 UUID 类型
#
# 业务逻辑：
# 将服务端的网元表主键修改为 UUID 类型，与客户端保持一致，
# 这样同步时可以直接使用客户端的 UUID 作为服务端的主键，
# 简化了同步逻辑，避免了 id 映射的复杂性。
#
# 技术实现：
# 1. 删除旧的外键约束
# 2. 修改 network_elements 表的 id 列类型为 string（UUID）
# 3. 修改 task_network_elements 表的 network_element_id 列类型为 string
# 4. 重新添加外键约束
#
class ChangeNetworkElementsIdToUuid < ActiveRecord::Migration[7.1]
  def change
    # 第一步：删除外键约束
    remove_foreign_key :task_network_elements, :network_elements if foreign_key_exists?(:task_network_elements, :network_elements)
    
    # 第二步：删除 task_network_elements 表上的相关索引
    remove_index :task_network_elements, name: 'idx_task_network_element_unique' if index_exists?(:task_network_elements, [:task_id, :network_element_id], name: 'idx_task_network_element_unique')
    
    # 第三步：修改 network_elements 表的 id 列类型为 string（UUID）
    change_table :network_elements do |t|
      t.change :id, :string, null: false
    end
    
    # 第四步：修改 task_network_elements 表的 network_element_id 列类型为 string
    change_table :task_network_elements do |t|
      t.change :network_element_id, :string, null: false
    end
    
    
  end
end

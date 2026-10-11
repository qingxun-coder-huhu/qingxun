# frozen_string_literal: true

# 删除不再需要的 local_id 列
#
# 业务逻辑：
# 现在我们直接使用客户端的 UUID 作为服务端的主键，
# 因此不再需要单独的 local_id 列来存储客户端 ID。
#
class RemoveLocalIdFromNetworkElements < ActiveRecord::Migration[7.1]
  def change
    # 删除索引
    
    if index_exists?(:network_elements, [:user_id, :local_id], name: 'index_network_elements_on_user_id_and_local_id')
      remove_index :network_elements, name: 'index_network_elements_on_user_id_and_local_id' 
    end
    
    # 删除列
    if column_exists?(:network_elements, :local_id)
      remove_column :network_elements, :local_id
    end
  end
end

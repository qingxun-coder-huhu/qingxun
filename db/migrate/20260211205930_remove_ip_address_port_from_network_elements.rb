class RemoveIpAddressPortFromNetworkElements < ActiveRecord::Migration[7.1]
  def change
    # 移除IP地址和端口字段（根据新的安全架构）
    remove_column :network_elements, :ip_address, :string
    remove_column :network_elements, :port, :integer
    
    # 添加设备型号字段（用于自动匹配巡检脚本）
    add_column :network_elements, :device_model, :string
    
    # 添加设备型号索引（用于快速搜索）
    add_index :network_elements, :device_model
  end
end

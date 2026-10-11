class AddPublicAndNotesToNetworkElements < ActiveRecord::Migration[7.1]
  def change
    add_column :network_elements, :public, :boolean, default: false
    add_column :network_elements, :notes, :text
  end
end

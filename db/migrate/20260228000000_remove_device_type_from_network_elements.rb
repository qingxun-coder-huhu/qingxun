# frozen_string_literal: true

class RemoveDeviceTypeFromNetworkElements < ActiveRecord::Migration[7.1]
  def change
    remove_column :network_elements, :device_type, :string
  end
end

class AddDeviceModelsToScripts < ActiveRecord::Migration[7.1]
  def change
    add_column :scripts, :device_models, :json
  end
end

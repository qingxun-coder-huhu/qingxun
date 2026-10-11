# frozen_string_literal: true

# 开源版：让"设备"具备真机连接能力，并新增任务执行结果表。
#
# 背景：线上版把连接凭据放在本地客户端，云端只存设备名称/型号；开源版是单一应用，
# 因此把 IP/账号/密码等连接信息直接加到 network_elements 上（密码列由 ActiveRecord
# 加密存储，见 config/initializers/active_record_encryption.rb）。
class AddDeviceConnectionFieldsAndTaskExecutions < ActiveRecord::Migration[7.1]
  def change
    change_table :network_elements, bulk: true do |t|
      t.string  :ip_address
      t.integer :port
      t.string  :connection_type, default: 'telnet', null: false
      t.string  :username
      t.text    :password            # 加密存储
      t.string  :enable_command
      t.text    :enable_password     # 加密存储
      t.text    :root_password       # 加密存储
      t.string  :ssh_key_path
    end

    create_table :task_executions do |t|
      t.references :task, null: false, foreign_key: true, index: true
      t.string  :network_element_id, null: false, index: true
      t.references :script, null: false, foreign_key: true, index: true
      t.string  :status, default: 'pending', null: false
      t.text    :logs
      t.json    :result, default: {}
      t.text    :error_message
      t.integer :duration_ms
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :task_executions, [:task_id, :network_element_id, :script_id],
              unique: true, name: 'index_task_executions_on_task_device_script'
  end
end

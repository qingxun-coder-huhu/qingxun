# frozen_string_literal: true

# 创建API使用日志表
#
# 业务逻辑：
# 记录所有API请求，用于审计、计费和分析。
#
class CreateApiUsageLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :api_usage_logs do |t|
      t.references :user, null: false
      t.string :endpoint, null: false
      t.string :method, null: false
      t.integer :status
      t.string :ip_address
      t.string :user_agent
      t.float :response_time
      t.json :request_params
      
      t.timestamps
    end
    
    add_index :api_usage_logs, [:user_id, :created_at]
    add_index :api_usage_logs, [:endpoint, :created_at]
  end
end

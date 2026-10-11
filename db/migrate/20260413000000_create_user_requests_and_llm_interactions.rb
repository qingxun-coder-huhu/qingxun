# frozen_string_literal: true

class CreateUserRequestsAndLlmInteractions < ActiveRecord::Migration[7.1]
  def change
    create_table :user_requests do |t|
      t.string :request_id, null: false
      t.integer :user_id, null: false
      t.string :request_type, null: false
      t.text :original_input, null: false
      t.string :status, default: 'pending'
      t.json :metadata, default: {}
      t.json :result, default: {}
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps

      t.index :request_id, unique: true
      t.index [:user_id, :created_at]
      t.index [:request_type, :created_at]
      t.index :status
    end

    create_table :llm_interactions do |t|
      t.string :user_request_id, null: false
      t.string :interaction_id, null: false
      t.string :service_name, null: false
      t.string :step_name
      t.string :model, null: false
      t.json :request_data, null: false
      t.json :response_data, null: false
      t.float :response_time_ms
      t.boolean :success, default: true
      t.text :error_message
      t.timestamps

      t.index :interaction_id, unique: true
      t.index :user_request_id
      t.index [:service_name, :created_at]
      t.index :model
      t.index [:user_request_id, :created_at]
    end

    # 添加外键约束（可选，确保数据完整性）
    add_foreign_key :llm_interactions, :user_requests, column: :user_request_id, primary_key: :request_id, on_delete: :cascade
    add_foreign_key :user_requests, :users, on_delete: :cascade
  end
end
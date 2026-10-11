# frozen_string_literal: true

class AddAsyncFieldsToChatSessions < ActiveRecord::Migration[7.1]
  def up
    unless column_exists?(:chat_sessions, :job_id)
      add_column :chat_sessions, :job_id, :string
    end

    unless column_exists?(:chat_sessions, :error_message)
      add_column :chat_sessions, :error_message, :text
    end

    unless column_exists?(:chat_sessions, :retry_count)
      add_column :chat_sessions, :retry_count, :integer, default: 0
    end

    unless column_exists?(:chat_sessions, :last_activity_at)
      add_column :chat_sessions, :last_activity_at, :datetime
    end

    # 添加索引（检查是否已存在）
    unless index_exists?(:chat_sessions, :job_id)
      add_index :chat_sessions, :job_id
    end

    unless index_exists?(:chat_sessions, :status)
      add_index :chat_sessions, :status
    end

    unless index_exists?(:chat_sessions, :last_activity_at)
      add_index :chat_sessions, :last_activity_at
    end
  end

  def down
    remove_column :chat_sessions, :job_id if column_exists?(:chat_sessions, :job_id)
    remove_column :chat_sessions, :error_message if column_exists?(:chat_sessions, :error_message)
    remove_column :chat_sessions, :retry_count if column_exists?(:chat_sessions, :retry_count)
    remove_column :chat_sessions, :last_activity_at if column_exists?(:chat_sessions, :last_activity_at)

    # 注意：不删除可能已存在的索引
  end
end

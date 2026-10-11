# frozen_string_literal: true

# 开源版清理：删除线上专属/已废弃的表。
#
# 这些表在上游被保留（历史包袱或将来可能复用），但开源版不再有对应模型，
# 留在 schema 里只会造成误解（例如 solid_queue_* 早已改用 :async 适配器）。
# 用 if_exists 保证在已有/全新库上都安全执行。
class DropOrphanTables < ActiveRecord::Migration[7.1]
  TABLES = %w[
    api_usage_logs
    chat_messages
    chat_sessions
    deactivated_users_archives
    feedbacks
    llm_interactions
    script_log_handoffs
    terms_versions
    user_consent_logs
    user_requests
    solid_queue_blocked_executions
    solid_queue_claimed_executions
    solid_queue_failed_executions
    solid_queue_jobs
    solid_queue_pauses
    solid_queue_processes
    solid_queue_ready_executions
    solid_queue_recurring_executions
    solid_queue_recurring_tasks
    solid_queue_scheduled_executions
    solid_queue_semaphores
  ].freeze

  def up
    # force: :cascade 处理表之间的外键依赖（如 solid_queue_* 互相关联）
    TABLES.each { |table| drop_table table, if_exists: true, force: :cascade }
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          '这些表属于线上版的功能，开源版不回建'
  end
end

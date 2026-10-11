# frozen_string_literal: true

# 引入"执行"实体：对齐本地客户端的 LocalTask / LocalTaskExecution（1 任务 → N 次执行）。
#
# 之前执行状态直接挂在 Task 上，重跑会覆盖，保留不了历史执行；现在每次运行建一条
# task_runs，执行单元（task_executions）归属到某次运行，页面默认看最新一次、并可回看历史。
class CreateTaskRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :task_runs do |t|
      t.references :task, null: false, foreign_key: true, index: true
      t.string  :status, default: 'pending', null: false
      t.integer :progress, default: 0, null: false
      t.jsonb   :result, default: {}
      t.text    :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_reference :task_executions, :task_run, foreign_key: true, null: true, index: true

    # 原唯一索引是 (task_id, network_element_id, script_id)：引入了多次运行后会挡住
    # 第二次运行写同样的"设备×脚本"。改为按运行维度唯一。
    remove_index :task_executions, name: 'index_task_executions_on_task_device_script'
    add_index :task_executions, [:task_run_id, :network_element_id, :script_id],
              unique: true, name: 'index_task_executions_on_run_device_script'
  end
end

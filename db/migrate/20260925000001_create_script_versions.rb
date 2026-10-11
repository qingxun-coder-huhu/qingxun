# frozen_string_literal: true

# 脚本版本历史。
#
# 业务逻辑：
#   脚本内容在自动生成、微调、自动保存、手动保存、标记调试完成与回滚时都会变化，本表按
#   "一次变化一份快照"留痕，供脚本页查看历史与回滚。`scripts.revision` 是当前版本的游标。
#
# 隐性知识：
#   1. 存的是**整份内容的快照**，不是 diff——回滚只需把某条快照写回 scripts，不必重放历史，
#      代价是 code / command_mapping 会重复存，脚本本身只有几 KB，可以接受。
#   2. 自动保存写得非常频繁（一次会话可能几十条），收敛逻辑不在这里、而在
#      ScriptVersionRecorder：同来源节流合并 + 内容相同不记。表结构保持"一条就是一条"。
#   3. 快照要连 command_mapping 与 branch_scenarios 一起存：只回退代码不回退测试映射，
#      会得到"代码是旧的、模拟环境是新的"这种更难排查的状态。
class CreateScriptVersions < ActiveRecord::Migration[7.1]
  def change
    create_table :script_versions do |t|
      # 外键带 ON DELETE CASCADE：版本离开脚本没有意义。AR 侧另有
      # Script has_many :script_versions, dependent: :destroy，两者都在——
      # cascade 是为了兜住**绕过回调的硬删**（实测：集成测试里用
      # `user.scripts.delete_all` 清理数据，只有 dependent 的话会撞外键）
      t.references :script, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :user_id, null: false
      t.integer :revision, null: false
      t.string :name
      t.text :description
      t.text :code
      # 主线描述（页面上那段"目标 + 步骤 + 命令 + 回显 + 处理逻辑 + 预期"）
      # 必须一起存：脚本是这份需求的产物，只有代码而看不到"当时要的是什么"，
      # 历史就是断的——回滚后需求框里会留着另一条需求的文本，最容易误导人
      t.text :initial_prompt
      t.json :command_mapping, default: {}
      t.json :device_models, default: []
      t.json :branch_scenarios, default: []
      # 调试状态也进快照：否则"标记调试完成"这种内容没变、只有状态变了的事件，
      # 会被内容去重吞掉，历史里看不到"这个版本被认可过"
      t.string :publish_status
      t.string :source, null: false
      t.timestamps
    end

    # 覆盖 script_id 单列查询，并保证同一脚本内 revision 不重复
    add_index :script_versions, [:script_id, :revision], unique: true
    add_index :script_versions, [:script_id, :created_at]

    # 当前版本游标：每写一条版本就递增，页面据此显示"当前 rN"
    add_column :scripts, :revision, :integer, null: false, default: 0
  end
end

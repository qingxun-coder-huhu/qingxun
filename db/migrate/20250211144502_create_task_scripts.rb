# frozen_string_literal: true

# 任务-脚本关联表迁移文件
#
# 业务逻辑：
# TaskScript模型建立任务与脚本的多对多关联。
# 一个任务可以包含多个脚本，一个脚本也可以被多个任务使用。
# 关联表存储脚本在任务中的执行顺序和参数，支持复杂的任务编排。
#
# 架构设计：
# 1. 解耦任务与脚本：任务定义不绑定具体脚本实现，便于脚本更新和替换
# 2. 参数传递：每个脚本可以有不同的执行参数，支持灵活配置
# 3. 执行控制：通过sequence和condition字段控制脚本执行逻辑
#
# 隐性知识：
# 1. 脚本执行顺序：通过sequence字段控制，支持串行和并行（相同sequence值）
# 2. 条件执行：condition字段支持Ruby表达式，根据前置脚本结果决定是否执行
# 3. 参数模板：parameters支持变量替换，如{device_ip}、{device_name}
# 4. 超时控制：每个脚本可以有不同的超时时间，防止单个脚本阻塞任务
#
class CreateTaskScripts < ActiveRecord::Migration[7.1]
  def change
    create_table :task_scripts do |t|
      # 外键关联：任务ID
      t.references :task, null: false, foreign_key: true
      
      # 外键关联：脚本ID
      # 注意：脚本删除时，历史任务记录应保留（使用dependent: :nullify）
      t.references :script, null: false, foreign_key: true
      
      # 执行顺序：脚本在任务中的执行顺序
      # 业务逻辑：数值越小越先执行，相同数值的脚本并行执行
      t.integer :sequence, null: false, default: 0
      
      # 执行参数：JSON格式的脚本执行参数
      # 结构：{timeout: 30, retry: 3, variables: {...}}
      # 用途：脚本级别的配置覆盖，支持动态参数
      t.json :parameters, default: {}
      
      # 执行条件：Ruby表达式字符串
      # 示例：'previous_script_success? && device_type == "switch"'
      # 用途：条件执行，根据前置结果或设备属性决定是否执行
      t.text :condition
      
      # 预期结果：期望的脚本执行结果模式
      # 可选值：any（任意）, success（必须成功）, warning（允许警告）, etc.
      # 用途：结果验证和后续脚本的条件判断
      t.string :expected_result, default: 'success'
      
      # 执行状态：脚本在该任务中的状态
      # 可选值：pending（等待）, running（执行中）, success（成功）, failed（失败）, skipped（跳过）
      # 注意：脚本状态是设备无关的，设备级别的状态在关联表中
      t.string :status, null: false, default: 'pending'
      
      # 跳过原因：如果脚本被跳过，记录跳过原因
      t.string :skip_reason
      
      # 平均执行时长：历史平均执行时间（秒）
      # 用途：任务预计时长计算，进度预估
      t.float :average_duration
      
      # 成功次数：历史成功执行次数统计
      t.integer :success_count, default: 0
      
      # 失败次数：历史失败执行次数统计
      t.integer :failure_count, default: 0
      
      # 时间戳：记录创建和更新时间
      t.timestamps
      
      # 复合索引：任务-脚本唯一性约束
      t.index [:task_id, :script_id], unique: true, name: 'idx_task_script_unique'
      
      # 执行顺序索引：便于按顺序查询脚本
      t.index [:task_id, :sequence], name: 'idx_task_sequence'
      
      # 状态索引：便于按状态筛选脚本
      t.index :status
      
      # 条件索引：便于查询有条件执行的脚本
      t.index :condition, where: "condition IS NOT NULL"
    end
    
    # 添加注释说明关联表的业务用途（SQLite不支持COMMENT语法，此处为代码注释）
    # SQLite不支持表注释和列注释，以下为文档说明：
    # 表用途：任务-脚本关联表：建立任务与脚本的多对多关联，控制脚本执行顺序和参数
    # 字段说明：
    #   task_id - 关联的任务ID，外键约束
    #   script_id - 关联的脚本ID，外键约束
    #   sequence - 执行顺序，数值越小越先执行，相同值并行执行
    #   parameters - JSON格式的脚本执行参数，支持变量替换
    #   condition - Ruby条件表达式，决定脚本是否执行
    #   expected_result - 预期执行结果：success|warning|any等
    #   status - 脚本执行状态：pending|running|success|failed|skipped
    #   skip_reason - 脚本跳过执行的原因
    #   average_duration - 历史平均执行时长（秒），用于进度预估
    #   success_count - 历史成功执行次数统计
    #   failure_count - 历史失败执行次数统计
  end
end
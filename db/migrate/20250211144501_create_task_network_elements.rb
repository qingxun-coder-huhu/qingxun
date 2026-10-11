# frozen_string_literal: true

# 任务-网元关联表迁移文件
#
# 业务逻辑：
# TaskNetworkElement模型建立任务与网元设备的多对多关联。
# 一个任务可以包含多个设备，一个设备也可以被多个任务使用（历史任务）。
# 关联表存储设备在任务中的执行状态和结果，便于细粒度追踪。
#
# 架构设计：
# 1. 解耦任务与设备：任务定义不绑定具体设备，便于任务模板复用
# 2. 执行状态追踪：每个设备的执行状态独立管理，支持部分成功
# 3. 结果存储：存储每个设备的执行结果和输出，便于问题定位
#
# 隐性知识：
# 1. 设备执行顺序：可通过sequence字段控制执行顺序（默认为创建顺序）
# 2. 设备过滤：某些设备可能被标记为跳过（skip_reason）
# 3. 结果存储：output字段可能包含大量数据，需考虑存储优化
# 4. 客户端模式：云端只存储设备基本信息，实际连接信息在客户端本地
#
class CreateTaskNetworkElements < ActiveRecord::Migration[7.1]
  def change
    create_table :task_network_elements do |t|
      # 外键关联：任务ID
      # 级联删除：任务删除时关联记录也被删除
      t.references :task, null: false, foreign_key: true
      
      # 外键关联：网元ID
      # 注意：设备删除时，历史任务记录应保留（使用dependent: :nullify或保留ID）
      t.references :network_element, null: false, foreign_key: true
      
      # 执行状态：设备在该任务中的状态
      # 可选值：pending（等待）, running（执行中）, success（成功）, failed（失败）, skipped（跳过）
      # 业务逻辑：独立于任务状态，支持设备级别的重试
      t.string :status, null: false, default: 'pending'
      
      # 执行顺序：设备在任务中的执行顺序
      # 用途：控制串行执行顺序，默认为0（按关联顺序）
      t.integer :sequence, default: 0
      
      # 开始时间：设备开始执行的时间
      t.datetime :started_at
      
      # 完成时间：设备执行完成的时间
      t.datetime :completed_at
      
      # 执行时长：设备执行耗时（秒）
      # 计算方式：completed_at - started_at
      t.float :duration
      
      # 执行结果：JSON格式的设备执行结果
      # 结构：{exit_code: 0, output: "...", error: "...", warnings: [...]}
      # 用途：细粒度问题定位，报告生成
      t.json :result, default: {}
      
      # 输出内容：脚本执行的标准输出
      # 注意：可能包含大量数据，考虑使用text或单独存储
      t.text :output
      
      # 错误信息：设备执行失败的错误描述
      t.text :error_message
      
      # 跳过原因：如果设备被跳过，记录跳过原因
      # 场景：设备离线、不兼容脚本、手动跳过等
      t.string :skip_reason
      
      # 重试次数：设备执行失败后的重试次数
      t.integer :retry_count, default: 0
      
      # 客户端设备ID：客户端本地存储的设备标识
      # 架构设计：客户端执行模式下，云端设备与客户端本地设备关联
      t.string :client_device_id
      
      # 时间戳：记录创建和更新时间
      t.timestamps
      
      # 复合索引：任务-设备唯一性约束
      t.index [:task_id, :network_element_id], unique: true, name: 'idx_task_network_element_unique'
      
      # 状态索引：便于按状态筛选设备
      t.index :status
      
      # 执行顺序索引：便于按顺序查询设备
      t.index :sequence
      
      # 时间索引：便于按时间范围查询执行记录
      t.index :started_at
      t.index :completed_at
    end
    
    # 添加注释说明关联表的业务用途（SQLite不支持COMMENT语法，此处为代码注释）
    # SQLite不支持表注释和列注释，以下为文档说明：
    # 表用途：任务-网元关联表：建立任务与设备的多对多关联，存储设备执行状态
    # 字段说明：
    #   task_id - 关联的任务ID，外键约束
    #   network_element_id - 关联的网元ID，外键约束
    #   status - 设备执行状态：pending|running|success|failed|skipped
    #   sequence - 执行顺序，控制串行执行顺序
    #   started_at - 设备开始执行时间
    #   completed_at - 设备执行完成时间
    #   duration - 执行时长（秒）
    #   result - JSON格式的执行结果详情
    #   output - 脚本执行的标准输出内容
    #   error_message - 设备执行失败的错误信息
    #   skip_reason - 设备跳过执行的原因
    #   retry_count - 执行失败后的重试次数
    #   client_device_id - 客户端本地设备ID，用于云端-客户端设备关联
  end
end
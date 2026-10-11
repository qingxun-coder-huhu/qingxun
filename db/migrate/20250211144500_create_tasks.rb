# frozen_string_literal: true

# 任务主表迁移文件
#
# 业务逻辑：
# Task模型代表用户创建的批量执行任务，替代原有的文件系统存储。
# 任务可以是：设备巡检、配置批量下发、故障排查等批量操作。
# 支持复杂的任务编排：多设备并行执行、多脚本顺序执行、条件判断等。
#
# 架构演进：
# 1. 原有系统：任务存储在tmp/tasks/目录的JSON文件中，日志存储在logs/目录
# 2. 新系统：任务存储在数据库，支持更好的状态管理、进度追踪和用户隔离
# 3. 兼容性：逐步迁移现有任务文件到数据库，保持与NetCat::TaskManager的集成
#
# 隐性知识：
# 1. 任务状态机：pending -> running -> completed/failed/cancelled
# 2. 进度计算基于已完成的设备-脚本组合数
# 3. 执行参数JSON包含超时、重试、并行度等配置
# 4. 结果JSON包含每个设备-脚本的执行详情和输出
# 5. 客户端执行模式下，云端只存储任务定义和结果，不存储中间日志
#
class CreateTasks < ActiveRecord::Migration[7.1]
  def change
    create_table :tasks do |t|
      # 任务名称：用户定义的任务标识
      # 业务需求：在用户范围内唯一，便于识别和追踪
      t.string :name, null: false
      
      # 任务描述：自然语言描述任务目标和范围
      # 用途：任务列表显示、执行记录说明
      t.text :description
      
      # 任务状态：状态机枚举
      # 可选值：pending（等待）, running（执行中）, completed（完成）, failed（失败）, cancelled（取消）
      # 业务逻辑：控制任务生命周期，防止重复执行
      t.string :status, null: false, default: 'pending'
      
      # 执行模式：云端执行或客户端执行
      # 可选值：cloud（云端执行）, client（客户端执行）
      # 架构设计：敏感信息在客户端执行模式下由客户端本地处理
      t.string :execution_mode, null: false, default: 'cloud'
      
      # 进度百分比：0-100
      # 计算方式：已完成的(设备×脚本)数 / 总(设备×脚本)数 × 100
      # 实时更新：每个设备-脚本执行完成后更新进度
      t.integer :progress, default: 0
      
      # 设备数量：任务关联的设备总数
      # 预计算字段：便于统计和显示
      t.integer :device_count, default: 0
      
      # 脚本数量：任务关联的脚本总数
      # 预计算字段：便于统计和显示
      t.integer :script_count, default: 0
      
      # 执行参数：JSON格式的任务配置
      # 包含：timeout（超时时间）, retry_count（重试次数）, parallel_level（并行度）, etc.
      t.json :execution_params, default: {}
      
      # 任务结果：JSON格式的执行结果汇总
      # 结构：{total: X, success: Y, failed: Z, details: [...]}
      # 用途：任务报告生成、统计分析
      t.json :result, default: {}
      
      # 开始时间：任务开始执行的时间
      # 业务逻辑：用于计算执行时长、超时判断
      t.datetime :started_at
      
      # 完成时间：任务完成（成功/失败/取消）的时间
      # 用途：执行效率分析、历史记录查询
      t.datetime :completed_at
      
      # 错误信息：任务失败时的错误描述
      # 存储：最后一次失败的错误信息，便于问题排查
      t.text :error_message
      
      # 所属用户：外键关联到users表
      # 权限控制：用户只能管理自己的任务
      t.references :user, null: false, foreign_key: true
      
      # 客户端任务ID：客户端本地存储的任务标识
      # 架构设计：客户端执行模式下，云端任务与客户端本地任务关联
      t.string :client_task_id
      
      # 时间戳：记录创建和更新时间
      t.timestamps
      
      # 复合索引：确保同一用户下的任务名称唯一
      t.index [:user_id, :name], unique: true
      
      # 状态索引：便于按状态筛选任务
      t.index :status
      
      # 执行模式索引：便于按执行模式筛选
      t.index :execution_mode
      
      # 进度索引：便于查询进行中的任务
      t.index :progress
      
      # 时间范围索引：便于按时间范围查询
      t.index :created_at
      t.index :started_at
      t.index :completed_at
    end
    
    # 添加注释说明表用途和执行模式差异（SQLite不支持COMMENT语法，此处为代码注释）
    # SQLite不支持表注释和列注释，以下为文档说明：
    # 表用途：任务主表：存储批量执行任务，支持云端和客户端两种执行模式
    # 字段说明：
    #   name - 任务名称，在用户范围内唯一
    #   description - 任务描述，说明任务目标和范围
    #   status - 任务状态：pending|running|completed|failed|cancelled
    #   execution_mode - 执行模式：cloud（云端执行）|client（客户端执行）
    #   progress - 执行进度百分比，0-100
    #   device_count - 关联的设备总数，预计算字段
    #   script_count - 关联的脚本总数，预计算字段
    #   execution_params - JSON格式的执行参数配置
    #   result - JSON格式的执行结果汇总
    #   started_at - 任务开始执行时间
    #   completed_at - 任务完成时间
    #   error_message - 任务失败时的错误信息
    #   user_id - 所属用户ID，外键约束
    #   client_task_id - 客户端本地任务ID，用于云端-客户端任务关联
  end
end
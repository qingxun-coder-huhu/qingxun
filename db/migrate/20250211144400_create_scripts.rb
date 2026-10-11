# frozen_string_literal: true

# 脚本表迁移文件
#
# 业务逻辑：
# Script模型用于存储用户创建的设备脚本模板，替代原有的文件系统存储。
# 脚本可以是：巡检脚本、配置脚本、故障排查脚本等，通过自然语言生成或手动编写。
# 支持版本管理，便于迭代更新和回滚。
#
# 架构演进：
# 1. 原有系统：脚本存储在scripts/generated/目录，基于时间戳命名
# 2. 新系统：脚本存储在数据库，支持更好的搜索、版本管理和用户隔离
# 3. 兼容性：迁移现有脚本文件到数据库，保持API向后兼容
#
# 隐性知识：
# 1. 命令映射（command_mapping）是JSON结构，用于自然语言与CLI命令的映射
# 2. 脚本版本号使用语义化版本（major.minor.patch），便于依赖管理
# 3. 设备类型数组支持脚本适配多种设备，提高复用性
# 4. 标签系统便于脚本分类和搜索，支持批量操作
#
class CreateScripts < ActiveRecord::Migration[7.1]
  def change
    create_table :scripts do |t|
      # 脚本名称：用户定义的脚本标识
      # 业务需求：在用户范围内唯一，便于识别和引用
      t.string :name, null: false
      
      # 脚本描述：自然语言描述脚本功能
      # 用途：脚本生成时的参考，用户界面的说明文本
      t.text :description, null: false
      
      # 脚本代码：Ruby代码内容
      # 存储：完整的Ruby类定义，继承自NetCat::DeviceScript
      # 格式要求：必须是有效的Ruby语法，可通过语法检查
      t.text :code, null: false
      
      # 命令映射：JSON格式的自然语言到CLI命令映射
      # 结构：{"show version": "show version", "check interface": "show interface status"}
      # 用途：脚本调试和大模型任务编排时的命令解析
      t.json :command_mapping, default: {}
      
      # 设备类型：脚本适用的设备类型数组
      # 格式：JSON数组，如["switch", "router"]
      # 业务逻辑：脚本只能在与适配设备类型的网元上执行
      t.json :device_types, default: []
      
      # 标签：脚本分类标签数组
      # 格式：JSON数组，如["巡检", "配置", "安全"]
      # 用途：脚本筛选、分类展示、批量操作
      t.json :tags, default: []
      
      # 版本号：语义化版本（semver）
      # 格式：字符串，如"1.0.0"
      # 管理：每次更新时递增版本，支持版本回滚
      t.string :version, null: false, default: "1.0.0"
      
      # 是否为公开脚本：其他用户可见/可用
      # 业务场景：用户可以选择分享自己的脚本模板给社区
      t.boolean :public, default: false
      
      # 使用次数：统计脚本被任务引用的次数
      # 用途：热门脚本推荐、质量评估
      t.integer :usage_count, default: 0
      
      # 所属用户：外键关联到users表
      # 权限控制：用户只能管理自己的脚本（公开脚本只读）
      t.references :user, null: false, foreign_key: true
      
      # 父脚本ID：用于版本管理
      # 当创建新版本时，指向原脚本ID
      # 用途：版本历史追踪、差异比较
      t.references :parent_script, foreign_key: { to_table: :scripts }
      
      # 时间戳：记录创建和更新时间
      t.timestamps
      
      # 复合索引：确保同一用户下的脚本名称唯一
      t.index [:user_id, :name], unique: true
      
      # 设备类型索引：PostgreSQL需要jsonb类型，暂时禁用GIN索引
      # t.index :device_types, using: :gin

      # 标签索引：PostgreSQL需要jsonb类型，暂时禁用GIN索引
      # t.index :tags, using: :gin
      
      # 公开脚本索引：便于快速查询公共脚本库
      t.index :public
    end
    
    # 添加注释说明表用途和迁移策略（SQLite不支持COMMENT语法，此处为代码注释）
    # SQLite不支持表注释和列注释，以下为文档说明：
    # 表用途：脚本表：存储设备脚本模板，支持版本管理和用户隔离
    # 字段说明：
    #   name - 脚本名称，在用户范围内唯一
    #   description - 脚本功能描述，用于自然语言生成参考
    #   code - Ruby脚本代码，继承自NetCat::DeviceScript
    #   command_mapping - JSON格式的命令映射，自然语言到CLI命令
    #   device_types - JSON数组，脚本适用的设备类型
    #   tags - JSON数组，脚本分类标签
    #   version - 语义化版本号，格式：major.minor.patch
    #   public - 是否公开，公开脚本可供其他用户查看和使用
    #   usage_count - 使用次数统计，用于热门推荐
    #   user_id - 所属用户ID，外键约束
    #   parent_script_id - 父脚本ID，用于版本历史管理
  end
end
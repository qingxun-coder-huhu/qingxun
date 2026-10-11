# frozen_string_literal: true

# 网元表迁移文件
#
# 业务逻辑：
# 网元（Network Element）代表用户管理的网络设备，如交换机、路由器、防火墙等。
# 根据架构设计，敏感信息（IP地址、用户名、密码）存储在客户端本地，云端只存储基本信息。
# 这样设计既保护了用户敏感数据，又能在云端进行任务编排和脚本管理。
#
# 安全考虑：
# 1. 不存储敏感连接信息（IP、密码等），这些由客户端本地管理
# 2. 用户只能访问自己创建的网元设备（通过user_id外键约束）
# 3. 设备名称在用户范围内唯一，便于识别和管理
#
# 隐性知识：
# 1. 设备类型使用枚举值，便于分类和脚本适配
# 2. 备注字段支持Markdown格式，便于详细描述设备配置
# 3. 客户端通过设备ID与本地存储的敏感信息关联
# 4. 云端任务编排时，只传递设备ID，客户端负责解析具体连接信息
#
class CreateNetworkElements < ActiveRecord::Migration[7.1]
  def change
    create_table :network_elements do |t|
      # 设备名称：用户自定义的设备标识
      # 业务需求：在用户范围内唯一，便于快速识别
      t.string :name, null: false
      
      # 设备类型：预定义的类型枚举
      # 可选值：switch（交换机）、router（路由器）、firewall（防火墙）、server（服务器）
      # 用途：脚本适配、界面图标显示、自动化模板选择
      t.string :device_type, null: false
      
      # IP地址：设备网络地址（可选）
      # 注意：根据安全架构，敏感信息应存储在客户端本地
      # 云端存储的IP地址仅用于显示和标识，实际连接使用客户端本地存储的完整信息
      t.string :ip_address
      
      # 端口号：连接端口（可选，默认根据协议决定）
      # 典型值：SSH-22, Telnet-23, HTTP-80, HTTPS-443
      t.integer :port
      
      # 描述/备注：设备详细说明
      # 格式：支持Markdown，可包含配置信息、位置、负责人等
      t.text :description
      
      # 所属用户：外键关联到users表
      # 权限控制：用户只能管理自己的设备
      t.references :user, null: false, foreign_key: true
      
      # 时间戳：记录创建和更新时间
      t.timestamps
      
      # 复合索引：确保同一用户下的设备名称唯一
      t.index [:user_id, :name], unique: true
      
      # 设备类型索引：便于按类型筛选
      t.index :device_type
    end
    
    # 添加注释说明表用途和安全考虑（SQLite不支持COMMENT语法，此处为代码注释）
    # SQLite不支持表注释和列注释，以下为文档说明：
    # 表用途：网元表：存储网络设备基本信息，敏感连接信息由客户端本地存储
    # 字段说明：
    #   name - 设备名称，在用户范围内唯一
    #   device_type - 设备类型：switch|router|firewall|server等
    #   ip_address - 设备IP地址（仅用于显示，实际连接使用客户端本地存储）
    #   port - 连接端口号（可选）
    #   description - 设备描述，支持Markdown格式
    #   user_id - 所属用户ID，外键约束
  end
end
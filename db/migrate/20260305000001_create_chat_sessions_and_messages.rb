# frozen_string_literal: true

# 结对编程助手会话和消息表迁移文件
#
# 业务逻辑：
# ChatSession 模型用于存储用户在结对编程助手中的会话状态。
# ChatMessage 模型用于存储会话中的消息历史。
# 用户可以通过对话式界面自然地提供命令-报文-处理逻辑，
# 系统通过引导式对话收集信息，逐组生成解析函数并验证，
# 最终汇总生成完整脚本并测试评估。
#
# 架构设计：
# 1. 使用 UUID 作为主键，便于分布式系统同步
# 2. chat_sessions.session_state 列使用 JSON 格式存储灵活的会话状态
# 3. chat_messages.metadata 列使用 JSON 格式存储消息元数据
# 4. status 列使用枚举管理会话状态
# 5. 所有用户数据通过 user_id 进行隔离
#
# 隐性知识：
# 1. session_state 结构包含当前阶段、处理组列表、评估历史、元数据等
# 2. 每个处理组包含命令、报文、处理逻辑、生成的代码、评估状态等
# 3. 消息角色分为 user（用户）、assistant（助手）、system（系统提示）
#
class CreateChatSessionsAndMessages < ActiveRecord::Migration[7.1]
  def change
    # 创建聊天会话表
    create_table :chat_sessions, id: false do |t|
      # UUID 主键：使用字符串类型存储 UUID
      # 业务需求：与现有 NetworkElement 模式保持一致
      t.string :id, primary_key: true, limit: 36, null: false

      # 会话名称：用户自定义的会话标识
      # 用途：便于用户识别和管理多个会话
      t.string :name, limit: 100

      # 会话状态：枚举类型
      # 可选值：welcome（欢迎阶段）、collecting（收集输入）、clarifying（澄清中）、
      #         processing（处理中）、testing（测试中）、evaluating（评估中）、
      #         reevaluating（重新评估）、complete（已完成）
      t.string :status, null: false, default: 'welcome'

      # 会话状态数据：JSON 格式存储完整的工作流状态
      # 结构示例：
      # {
      #   current_phase: 'welcome',  # 当前阶段
      #   processing_groups: [       # 处理组列表
      #     {
      #       id: 1,
      #       command: 'show version',
      #       response: 'Version 1.0.0',
      #       processing_logic: '提取版本号',
      #       generated_code: 'def parse_version...',
      #       evaluation_status: 'pending',  # pending/generating/generated/evaluating/passed/failed/skipped
      #       evaluation_history: [],
      #       confirmed: false
      #     }
      #   ],
      #   current_group_index: 0,     # 当前处理的组索引
      #   evaluation_history: [],      # 评估历史记录
      #   final_script: nil,           # 最终生成的脚本
      #   final_evaluation: nil,       # 最终评估结果
      #   metadata: {                  # 元数据
      #     device_model: 'Cisco Catalyst',
      #     created_at: '...'
      #   }
      # }
      t.json :session_state, default: {}

      # 所属用户：外键关联到 users 表
      # 权限控制：用户只能访问自己的会话
      t.integer :user_id, null: false

      # 时间戳：记录创建和更新时间
      t.timestamps
    end

    # 创建聊天消息表
    create_table :chat_messages, id: false do |t|
      # UUID 主键
      t.string :id, primary_key: true, limit: 36, null: false

      # 所属会话：外键关联到 chat_sessions 表
      t.string :chat_session_id, limit: 36, null: false

      # 消息角色：枚举类型
      # 可选值：user（用户消息）、assistant（助手消息）、system（系统提示）
      t.string :role, null: false, limit: 20

      # 消息内容：文本内容
      t.text :content, null: false

      # 消息元数据：JSON 格式存储额外信息
      # 结构示例：
      # {
      #   message_type: 'text'|'options'|'code'|'evaluation_result',
      #   options: [...],           # 如果是选项消息，存储选项列表
      #   code_block: '...',        # 如果包含代码，存储代码内容
      #   evaluation_data: {...},   # 评估数据
      #   processing_group_id: 1,   # 关联的处理组ID
      #   timestamp: '...'
      # }
      t.json :metadata, default: {}

      # 时间戳：记录创建和更新时间
      t.timestamps
    end

    # 添加索引（手动添加避免与 t.references 冲突）
    add_index :chat_sessions, :user_id, name: 'index_chat_sessions_on_user_id'
    add_index :chat_sessions, :status, name: 'index_chat_sessions_on_status'
    add_index :chat_sessions, :created_at, name: 'index_chat_sessions_on_created_at'
    add_foreign_key :chat_sessions, :users

    add_index :chat_messages, :chat_session_id, name: 'index_chat_messages_on_chat_session_id'
    add_index :chat_messages, :role, name: 'index_chat_messages_on_role'
    add_index :chat_messages, :created_at, name: 'index_chat_messages_on_created_at'
    add_foreign_key :chat_messages, :chat_sessions

    # SQLite 不支持表注释和列注释，以下为文档说明：
    #
    # chat_sessions 表用途：结对编程助手会话表：存储对话式脚本开发的会话状态
    # chat_sessions 字段说明：
    #   id - UUID 主键，字符串类型（36字符）
    #   name - 会话名称，可选，便于用户识别
    #   status - 会话状态：welcome|collecting|clarifying|processing|testing|evaluating|reevaluating|complete
    #   session_state - JSON 格式的会话状态数据
    #   user_id - 所属用户ID，外键约束
    #
    # chat_messages 表用途：结对编程助手消息表：存储会话中的消息历史
    # chat_messages 字段说明：
    #   id - UUID 主键，字符串类型（36字符）
    #   chat_session_id - 所属会话ID，外键约束
    #   role - 消息角色：user|assistant|system
    #   content - 消息文本内容
    #   metadata - JSON 格式的消息元数据
  end
end

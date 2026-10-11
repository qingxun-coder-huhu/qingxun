# frozen_string_literal: true

# 创建条款版本表
#
# 业务逻辑：
# 存储服务条款和隐私政策的历史版本，确保法律合规性。
# 每次更新条款时创建新记录，保留完整的变更历史。
#
# 安全考虑：
# 1. 条款内容不可修改（只读），只能创建新版本
# 2. 记录创建时间用于审计追踪
# 3. is_current 标识当前生效版本
#
class CreateTermsVersions < ActiveRecord::Migration[7.1]
  def change
    create_table :terms_versions do |t|
      # 版本号，使用日期格式如 "2026-04-08"
      t.string :version, null: false, index: { unique: true }, comment: '条款版本号'

      # 服务条款完整内容
      t.text :terms_content, null: false, comment: '服务条款内容'

      # 隐私政策完整内容
      t.text :privacy_content, null: false, comment: '隐私政策内容'

      # 是否为当前生效版本
      t.boolean :is_current, default: false, null: false, comment: '是否为当前版本'

      # 版本说明（可选，记录变更点）
      t.text :change_notes, comment: '版本变更说明'

      t.timestamps
    end

    # 添加索引：当前版本查询优化
    add_index :terms_versions, :is_current, where: 'is_current = true', name: 'index_terms_versions_on_is_current'
  end
end

# frozen_string_literal: true

# 用户维护的设备型号清单。
#
# 业务逻辑：
#   脚本的"支持的设备型号"（scripts.device_models）是脚本与设备匹配的依据，此前靠用户手输。
#   同一个型号会被写成多种样子（大小写/空格不一致），匹配就落空。本表让用户先维护一份自己的
#   型号清单，脚本生成页从这份清单取候选并按名称排序展示。
#
# 隐性知识：
#   1. 型号是**用户私有**的：唯一性约束带 user_id 作用域。
#   2. 名称只 strip，不改大小写——品牌与型号的大小写本身有含义（"H3C"、"Cisco Catalyst"），
#      统一小写反而难读。查重因此用 LOWER(name) 的表达式唯一索引兜住大小写变体。
#   3. 外键带 ON DELETE CASCADE：型号清单离开用户没有意义；AR 侧另有
#      User has_many :device_models, dependent: :destroy 兜住回调路径。
class CreateDeviceModels < ActiveRecord::Migration[7.1]
  def change
    create_table :device_models do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false
      t.timestamps
    end

    add_index :device_models, :user_id
    # 同一用户下型号名唯一，且大小写不敏感（避免 "cisco 2960" 与 "Cisco 2960" 并存）
    add_index :device_models, 'user_id, LOWER(name)', unique: true,
                                                     name: 'index_device_models_on_user_and_lower_name'
  end
end

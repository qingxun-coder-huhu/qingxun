# frozen_string_literal: true

# 自定义集成：新增编辑历史（每次保存记录一份快照，供「查看历史」）。
# 与本地客户端一致的历史能力；不含云端的「服务器版本/同步」（开源版无云端）。
class AddHistoryToCustomIntegrations < ActiveRecord::Migration[7.1]
  def change
    add_column :custom_integrations, :history, :jsonb, default: [], null: false
  end
end

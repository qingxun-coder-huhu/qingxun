# frozen_string_literal: true

# 添加订阅套餐和使用量相关字段到用户表
#
# 业务逻辑：
# 为支持免费/订阅模式，需要记录用户的套餐等级、试用期信息、API令牌使用时间等。
# subscription_tier：标识用户当前套餐（free/basic/pro/enterprise）
# trial_ends_at：试用期结束时间，用于判断用户是否在试用期内
# api_token_last_used_at：记录API令牌最后使用时间，便于安全审计
#
class AddSubscriptionFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    # 订阅套餐等级
    add_column :users, :subscription_tier, :string, default: 'free', null: false
    add_index :users, :subscription_tier
    
    # 试用期结束时间
    add_column :users, :trial_ends_at, :datetime
    
    # API令牌最后使用时间（安全审计）
    add_column :users, :api_token_last_used_at, :datetime
    
    # 本月AI生成次数统计（使用计数器缓存）
    add_column :users, :monthly_ai_generations, :integer, default: 0, null: false
    
    # 本月任务执行次数统计
    add_column :users, :monthly_task_executions, :integer, default: 0, null: false
    
    # 统计月份（用于重置月度计数器）
    add_column :users, :statistics_month, :string
  end
end

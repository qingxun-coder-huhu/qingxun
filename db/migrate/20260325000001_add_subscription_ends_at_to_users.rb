# frozen_string_literal: true

# 添加订阅结束时间字段到用户表
#
# 业务逻辑：
# 在无法接入支付系统期间，管理员需要手动设置用户的订阅时长。
# subscription_ends_at：订阅结束时间，用于判断用户订阅是否有效
#
class AddSubscriptionEndsAtToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :subscription_ends_at, :datetime, comment: "订阅结束时间"

    # 为已存在的付费用户设置默认值（免费版不需要）
    reversible do |dir|
      dir.up do
        # 为所有非免费版用户设置1个月后的默认结束时间
        User.where.not(subscription_tier: 'free').find_each do |user|
          user.update!(subscription_ends_at: 1.month.from_now)
        end
      end
    end
  end
end
# frozen_string_literal: true

# 用户模型（开源版）
#
# 开源版没有账号体系：全局只有一个自动创建的「本地操作员」，用作脚本、任务、
# 设备等业务数据的归属。线上版围绕识别码、微信登录、激活邮件、账号注销的能力
# 已随账号体系一并移除，这里只保留最小实现。
class User < ApplicationRecord
  has_secure_password

  validates :email, presence: true, uniqueness: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, presence: true, length: { minimum: 6 }, on: :create

  has_many :network_elements, dependent: :destroy
  has_many :device_models, dependent: :destroy
  has_many :scripts, dependent: :destroy
  has_many :tasks, dependent: :destroy
  has_one  :custom_integration, dependent: :destroy

  # 本地操作员的固定邮箱
  LOCAL_OPERATOR_EMAIL = 'local@qingxun.local'

  # 幂等地取得（必要时创建）本地操作员。
  def self.local_operator
    find_or_create_by!(email: LOCAL_OPERATOR_EMAIL) do |u|
      u.password = SecureRandom.hex(16)
      u.activated = true
      u.admin = true
    end
  end

  # activated 字段在部分历史库里可能缺省，缺省视为已激活。
  def activated?
    respond_to?(:activated) ? !!activated : true
  end
end

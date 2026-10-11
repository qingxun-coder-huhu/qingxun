# frozen_string_literal: true

require 'securerandom'

# 设备（网络设备）模型
#
# 开源版是单一应用：连接凭据（IP/账号/密码等）与设备信息存在同一处，
# 密码列由 ActiveRecord 加密存储（见 config/initializers/active_record_encryption.rb），
# 明文不落库、日志中也不出现。
#
# 隐性知识：
#   1. TelnetDevice.test_conn / DeviceRunner 期望设备对象响应
#      `ip_address / port / connection_type / username / enable_command /
#       decrypt_password / decrypt_enable_password`——这些方法在本模型上保持稳定，
#      以便直接复用 lib/telnet_device.rb。
#   2. 型号（device_model）用于把脚本匹配到设备。
class NetworkElement < ApplicationRecord
  self.primary_key = 'id'

  CONNECTION_TYPES = %w[telnet ssh].freeze

  encrypts :password
  encrypts :enable_password
  encrypts :root_password

  before_validation :generate_uuid, on: :create

  belongs_to :user
  has_many :task_network_elements, dependent: :destroy
  has_many :tasks, through: :task_network_elements
  has_many :task_executions, dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 }
  validates :device_model, length: { maximum: 100 }, allow_blank: true
  validates :user_id, presence: true
  validates :name, uniqueness: { scope: :user_id, message: '该设备名称已存在' }
  validates :connection_type, inclusion: { in: CONNECTION_TYPES }
  validates :port, numericality: { only_integer: true, in: 1..65_535 }, allow_nil: true

  def self.search(query, user_id = nil)
    query = query.to_s.strip
    return none if query.blank?

    result = where('name LIKE ? OR description LIKE ?', "%#{query}%", "%#{query}%")
    result = result.where(user_id: user_id) if user_id
    result
  end

  def self.active
    column_names.include?('active') ? where(active: true) : all
  end

  # 供 lib/telnet_device.rb 使用：设备是否配置了连接信息
  def connection_info?
    ip_address.present? && username.present?
  end

  # TelnetDevice 期望的解密读取方法
  def decrypt_password
    password
  end

  def decrypt_enable_password
    enable_password
  end

  def decrypt_root_password
    root_password
  end

  def task_info
    result = { id: id, name: name, device_model: device_model, description: description }
    result[:active] = active if self.class.column_names.include?('active')
    result
  end

  def display_name
    "#{name} (##{id})"
  end

  def identifier
    "ne_#{id}_#{Digest::MD5.hexdigest("#{user_id}#{name}")[0..7]}"
  end

  private

  def generate_uuid
    self.id ||= SecureRandom.uuid
  end
end

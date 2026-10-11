# frozen_string_literal: true

# 用户维护的设备型号
#
# 业务逻辑：
#   脚本生成页的"支持的设备型号"是脚本与设备匹配的依据（见 Script#validate_device_models
#   与 Script.search 的 device_model 过滤）。型号此前靠手输，写法不一致会让匹配落空；
#   本模型让每个用户先维护自己的型号清单，生成页据此给候选。
#
# 隐性知识：
#   1. 清单是**用户私有**的：唯一性带 user_id 作用域，控制器侧也按 current_user 隔离。
#   2. 默认排序按名称（忽略大小写）升序 —— 管理页与生成页下拉共用这一顺序，
#      "默认排序显示"要的是稳定、可预期，不能让数据库按写入顺序返回。
#   3. 名称只 strip，不改大小写：品牌与型号的大小写有含义（"H3C"、"Cisco Catalyst"）。
class DeviceModel < ApplicationRecord
  belongs_to :user

  before_validation :normalize_name

  validates :name, presence: true, length: { maximum: 100 }
  validates :name, uniqueness: { scope: :user_id, case_sensitive: false, message: '该设备型号已存在' }

  # 管理页与生成页共用的默认顺序
  scope :ordered, -> { order(Arel.sql('LOWER(name) ASC')) }

  private

  def normalize_name
    self.name = name.to_s.strip
  end
end

# frozen_string_literal: true

# 修改 users 表 activated 字段的默认值为 false
#
# 业务逻辑：
# 原始设计中 activated 字段默认值为 true，这导致新注册用户默认已激活，
# 与邮件激活流程冲突。为了支持完整的邮箱验证流程，需要将默认值改为 false。
#
# 安全考虑：
# 1. 新用户注册后必须通过邮箱验证才能激活账户
# 2. 防止垃圾注册和未经验证的账户访问系统
# 3. 已存在的用户不受影响（他们的 activated 值已经是 true）
#
# 注意：
# 此迁移只修改默认值，不会改变现有用户的 activated 值
class ChangeActivatedDefaultToFalse < ActiveRecord::Migration[7.1]
  def change
    change_column_default :users, :activated, from: true, to: false
  end
end
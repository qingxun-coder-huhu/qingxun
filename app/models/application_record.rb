# frozen_string_literal: true

# ApplicationRecord基类
#
# 业务逻辑：
# ApplicationRecord是所有ActiveRecord模型的基类，提供统一的配置和扩展点。
# 在清巡项目中，我们通过这个基类添加项目特定的功能和配置。
#
# 隐性知识：
# 1. Rails 5+要求所有模型继承自ApplicationRecord而非ActiveRecord::Base
# 2. 可以在这里添加全局的模型配置，如连接池设置、查询超时等
# 3. 适合添加项目范围的模型扩展，如审计日志、软删除等
# 4. 保持与Rails框架的兼容性，便于未来升级
#
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  
  # 全局配置：连接池和查询超时
  connects_to database: { writing: :primary, reading: :primary }
  
  # 全局作用域：按创建时间倒序排列（常用）
  scope :recent, -> { order(created_at: :desc) }
  
  # 全局方法：安全地获取记录，避免N+1查询
  def self.safe_find(id)
    find_by(id: id)
  end
  
  # 全局方法：批量更新时跳过验证（谨慎使用）
  def self.bulk_update(records, attributes)
    update_all(attributes) if records.any?
  end
  
  # 日志格式统一化
  def to_log_format
    {
      id: id,
      class: self.class.name,
      attributes: attributes.except('created_at', 'updated_at')
    }
  end
end
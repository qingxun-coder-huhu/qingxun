# frozen_string_literal: true

# 脚本模型
#
# 业务逻辑：
# Script模型代表用户创建的设备自动化脚本，是清巡平台的核心资产。
# 脚本通过自然语言生成或手动编写，用于网络设备的巡检、配置、故障排查等任务。
# 支持版本管理、设备类型适配、命令映射等高级功能。
#
# 架构演进：
# 1. 原有实现：脚本存储在文件系统（scripts/generated/），无版本管理和用户隔离
# 2. 新实现：数据库存储，支持多用户、版本控制、搜索和统计
# 3. 迁移策略：逐步将现有脚本文件导入数据库，保持API兼容性
#
# 隐性知识：
# 1. 命令映射JSON结构直接影响大模型任务编排的准确性
# 2. 设备类型适配确保脚本只在兼容设备上执行，避免错误
# 3. 版本管理支持迭代开发和回滚，特别适用于生产环境
# 4. 公开脚本功能为社区协作和知识共享提供基础
#
class Script < ApplicationRecord
  # 脚本唯一标识：16 位十六进制（SecureRandom.hex(8)）。
  # 在生成脚本页面初始化时确定，随脚本入库；生成的脚本类名后缀也用它，
  # 因此它必须在**整个应用范围内唯一**（DB 层有唯一索引兜底）。
  UID_LENGTH = 16

  # 命令映射树的最大嵌套层级。树是给模拟服务器做上下文切换用的，正常设备 CLI
  # 不会超过几层；这里设上限是为了拦住模型偶发的畸形深层嵌套。
  MAX_COMMAND_MAPPING_DEPTH = 10

  class << self
    # 生成一个未被占用的 script_uid；16 位随机碰撞概率可忽略，仍做查重兜底
    def generate_unique_uid
      10.times do
        candidate = SecureRandom.hex(UID_LENGTH / 2)
        return candidate unless where(script_uid: candidate).exists?
      end
      raise '无法生成唯一的 script_uid'
    end
  end

  # 关联关系
  belongs_to :user
  belongs_to :parent_script, class_name: 'Script', optional: true
  
  # 一个脚本可以被多个任务引用
  has_many :task_scripts, dependent: :destroy
  has_many :tasks, through: :task_scripts
  
  # 一个脚本可以有多个命令映射
  has_many :command_mappings, dependent: :destroy

  # 版本快照：每次内容有意义的变更留一条（见 ScriptVersionRecorder），
  # 页面的历史列表与回滚都读它。revision 列是当前版本的游标。
  has_many :script_versions, dependent: :destroy
  
  # 版本链：一个脚本可以有多个子版本
  has_many :child_scripts, class_name: 'Script', foreign_key: 'parent_script_id', dependent: :nullify
  
   # 调试状态枚举
   enum publish_status: { debugging: 'debugging', debugged: 'debugged' }
  
  # 序列化JSON字段（注释掉，因为JSON列原生支持序列化）
  # serialize :command_mapping, JSON
  # serialize :device_types, JSON
  # serialize :tags, JSON
  
  # 数据验证
  validates :name, presence: true, length: { maximum: 100 }
  validates :description, presence: true, length: { maximum: 1000 }
  validates :code, presence: true
  validates :version, presence: true, format: { with: /\A\d+\.\d+\.\d+\z/, message: "版本号格式应为X.Y.Z" }
  validates :user_id, presence: true

  # 唯一标识：应用范围内唯一，替代原先"同一用户下名称唯一"的身份语义
  validates :script_uid, presence: true, uniqueness: true,
                         format: { with: /\A[0-9a-f]{16}\z/, message: '格式应为 16 位十六进制' }

  # 自定义验证
  validate :validate_command_mapping_format
  validate :validate_device_models
  validate :validate_code_syntax, if: -> { code.present? && code_changed? }
  
  # 回调
  before_validation :normalize_tags
  before_validation :ensure_script_uid, on: :create
  after_save :increment_parent_usage, if: -> { parent_script_id.present? && saved_change_to_usage_count? }
  
  # 类方法
  
  # 搜索脚本
  # 参数：
  #   query: 搜索关键词（名称、描述、标签）
  #   user_id: 用户ID（nil表示搜索公开脚本）
  #   device_model: 设备型号筛选
  #   tag: 标签筛选
  # 返回：符合条件的脚本集合
  def self.search(query: nil, user_id: nil, device_model: nil, tag: nil)
    result = all
    
    # 用户范围：特定用户或公开脚本
    if user_id
      result = result.where(user_id: user_id)
    end
    
    # 关键词搜索
    if query.present?
      result = result.where("name LIKE ? OR description LIKE ?", "%#{query}%", "%#{query}%")
    end
    
    # 设备型号筛选
    if device_model.present?
      result = result.where("device_models @> ?", [device_model].to_json)
    end
    
    # 标签筛选
    if tag.present?
      result = result.where("tags @> ?", [tag].to_json)
    end
    
    result.order(usage_count: :desc, updated_at: :desc)
  end
  
  # 按设备型号分组统计
  def self.stats_by_device_model(user_id = nil)
    query = where(user_id: user_id)
    
    # 展开JSON数组并统计
    stats = {}
    query.find_each do |script|
      script.device_models.each do |device_model|
        stats[device_model] ||= 0
        stats[device_model] += 1
      end
    end
    
    stats
  end
  
  # 热门脚本（按使用次数排序）
  def self.popular(limit: 10, user_id: nil)
    query = where(user_id: user_id)
    query.order(usage_count: :desc, updated_at: :desc).limit(limit)
  end
  
  # 生成/微调后应该用的版本号（**不改自身**，由调用方赋值后统一保存）
  #
  # 业务逻辑：
  #   重新生成 = 按（可能更新过的）需求重新实现一版 → minor+1、patch 归零；
  #   微调     = 在既有实现上改动            → patch+1；
  #   其余来源（普通自动保存、手动保存、回滚等）原样返回，不动版本号。
  #
  # 隐性知识：
  #   1. 在加这个方法之前 `scripts.version` 恒为 '1.0.0'：另一个会递增的 `revision` 是
  #      **快照序号**，只在需求文本变化时才动（只改代码的微调不会动它），而且没有被任何 API
  #      暴露 —— 于是客户端下载到的版本号永远不变，"微调后版本应该变"这条无从体现。
  #   2. **普通自动保存不能涨版本**：用户每敲几个字就触发一次 autosave，跟着涨就是噪声。
  #      只有 generated / refined 这两种"确实重新生成过"的来源才涨。
  #   3. 下面那个 `create_new_version`（dup 出一行新脚本）是**死代码**，没有调用方；
  #      本方法是"同一个脚本的版本号推进"，语义不同，不要混用。
  def next_version_for(source)
    major, minor, patch = version.to_s.split('.').map(&:to_i)
    major = 1 if major.nil? || major <= 0

    case source.to_s
    when 'generated' then "#{major}.#{minor.to_i + 1}.0"
    when 'refined'   then "#{major}.#{minor.to_i}.#{patch.to_i + 1}"
    else version
    end
  end

  # 创建新版本
  # 参数：新版本属性
  # 返回：新版本脚本实例
  def create_new_version(attributes = {})
    new_version = dup
    
    # 递增版本号
    current_version_parts = version.split('.').map(&:to_i)
    current_version_parts[2] += 1  # 递增patch版本
    new_version_number = current_version_parts.join('.')
    
    # 设置新版本属性（script_uid 必须重新生成：它全局唯一，不能随 dup 复制）
    new_version.assign_attributes(
      attributes.merge(
        parent_script_id: id,
        version: new_version_number,
        usage_count: 0,
        script_uid: self.class.generate_unique_uid
      )
    )
    
    new_version.save
    new_version
  end
  
  # 获取版本历史
  def version_history
    history = []
    current = self
    
    # 向上追溯父版本
    while current
      history.unshift(current)
      current = current.parent_script
    end
    
    history
  end
  
  # 实例方法
  
  # 脚本完整显示名称
  def display_name
    "#{name} v#{version}"
  end
  
  # 是否为基础版本（无父版本）
  def base_version?
    parent_script_id.nil?
  end
  
  # 增加使用次数
  def increment_usage
    update(usage_count: usage_count + 1)
  end
  
  # 验证脚本代码语法
  # 使用Ruby的SyntaxError检查基本语法
  def valid_syntax?
    RubyVM::InstructionSequence.compile(code)
    true
  rescue SyntaxError => e
    errors.add(:code, "语法错误: #{e.message}")
    false
  end
  
  # 获取适用的设备型号显示名称
  def device_model_display_names
    device_models.map do |model|
      model.humanize
    end
  end
  
  # 脚本标识符（用于客户端和日志）
  def identifier
    "script_#{id}_#{Digest::MD5.hexdigest("#{user_id}#{name}#{version}")[0..7]}"
  end
  
  # 生成文件格式（兼容原有系统）
  # 返回：{filename: "xxx.rb", content: "代码内容"}
  def to_file_format
    timestamp = created_at.strftime("%Y%m%d_%H%M%S")
    {
      filename: "#{timestamp}_#{name.parameterize}.rb",
      content: code
    }
  end
  
  private
  
  # 验证命令映射格式
  #
  # 支持三种形态：
  #   - Hash（旧格式）：{ "命令" => "回显" }
  #   - Array（平铺）：[{ "command" =>, "response" => }]
  #   - 嵌套树：节点可带 "children"（命中该命令进入下一层）与
  #     "mock"（仅模拟服务器使用的导航元数据：exit_level）
  def validate_command_mapping_format
    return if command_mapping.blank?
    
    unless command_mapping.is_a?(Hash) || command_mapping.is_a?(Array)
      errors.add(:command_mapping, "必须是JSON对象或数组格式")
      return
    end
    
    # 如果是 Hash 格式，检查键值对
    if command_mapping.is_a?(Hash)
      command_mapping.each do |key, value|
        unless key.is_a?(String) && value.is_a?(String)
          errors.add(:command_mapping, "键和值都必须是字符串")
          break
        end
      end
    end

    validate_mapping_nodes(command_mapping) if command_mapping.is_a?(Array)
  end

  # 递归校验映射节点数组。
  #
  # 隐性知识：
  #   mock 里只认 exit_level。这里**刻意不校验、也不支持提示符字段**：提示符因设备而异，
  #   映射里写死它会让生成的脚本依赖某个具体提示符。曾经有过 mock.prompt，已删除。
  #   出错即返回，避免同一类问题在每层重复上报。
  def validate_mapping_nodes(nodes, depth = 0)
    if depth > MAX_COMMAND_MAPPING_DEPTH
      errors.add(:command_mapping, "嵌套层级过深（最多 #{MAX_COMMAND_MAPPING_DEPTH} 层）")
      return
    end

    nodes.each do |item|
      unless item.is_a?(Hash) && item.key?('command') && item.key?('response')
        errors.add(:command_mapping, "数组元素必须包含 'command' 和 'response' 键")
        return
      end

      unless item['response'].is_a?(String)
        errors.add(:command_mapping, "'response' 必须是字符串（空字符串表示无回显）")
        return
      end

      mock = item['mock']
      if mock.present?
        unless mock.is_a?(Hash)
          errors.add(:command_mapping, "'mock' 必须是对象")
          return
        end

        exit_level = mock['exit_level']
        unless exit_level.nil? || (exit_level.is_a?(Integer) && exit_level >= 0)
          errors.add(:command_mapping, "'mock.exit_level' 必须是不小于 0 的整数（0 表示回到根上下文）")
          return
        end
      end

      children = item['children']
      next if children.nil?

      unless children.is_a?(Array)
        errors.add(:command_mapping, "'children' 必须是数组")
        return
      end

      validate_mapping_nodes(children, depth + 1)
      return if errors[:command_mapping].any?
    end
  end
  
  # 验证设备型号
  #
  # 隐性知识：型号只在**「调试完成」时**必须给出。生成脚本页是先生成代码、后填型号，自动保存
  # 要能在型号还空着时就把内容存下来（否则刷新就丢）；而型号参与脚本与设备的匹配，所以
  # "这个脚本能不能被任务选中"必须卡在调试完成这道关上，不能靠草稿阶段拦。
  def validate_device_models
    # 草稿（调试中）允许没有型号
    return if device_models.blank? && publish_status != 'debugged'

    if device_models.blank?
      errors.add(:device_models, "不能为空（标记「调试完成」前请填写支持的设备型号）")
      return
    end

    unless device_models.is_a?(Array)
      errors.add(:device_models, "必须是JSON数组格式")
      return
    end

    # 检查数组不为空
    if device_models.empty?
      errors.add(:device_models, "至少需要一个设备型号")
    end
  end
  
  # 验证代码语法
  def validate_code_syntax
    return if valid_syntax?
    
    # 错误信息已在valid_syntax?方法中添加
  end
  
  # 规范化标签（去重、小写、排序）
  def normalize_tags
    return if tags.blank?
    
    self.tags = tags.map(&:to_s).map(&:downcase).uniq.sort
  end

  # 创建时若未显式指定 script_uid 则生成一个，保证直接 Script.create! 的路径也能入库
  def ensure_script_uid
    self.script_uid = self.class.generate_unique_uid if script_uid.blank?
  end
  
  # 增加父脚本的使用次数
  def increment_parent_usage
    parent_script.increment!(:usage_count)
  end
end
# frozen_string_literal: true

# 任务定义的格式转换（逐字复用自本地客户端 net_cat_client/lib/task_info_converter.rb）。
#
# 业务逻辑：
#   云端返回、以及本地保存过的任务定义并不总是同一种形状，目前至少要认这三种：
#     1. 简单格式:            { devices: [...], scripts: [...] }
#     2. 按设备型号分组:      { "Huawei AR2200" => { devs: [...], scripts: [...] }, ... }
#     3. 包在 task_json 里:   { task_json: <上面任意一种> }
#   本模块把它们统一成 { devices: [...], scripts: [...] }，并按 id 去重。
#
# 隐性知识：
#   键既有字符串也有符号两种写法，历史数据里两种都存在，所以取值一律走 get/key? 辅助方法，
#   不要直接写 data['devices']。
module TaskInfoConverter
  EMPTY = { devices: [], scripts: [] }.freeze

  module_function

  # @param definition [Object] 任务定义（Hash 或任何其他类型）
  # @return [Hash] { devices: Array, scripts: Array }
  def convert(definition)
    data = unwrap(definition)
    return EMPTY.dup unless data.is_a?(Hash)

    devices = []
    scripts = []

    if key?(data, 'devices')
      # 简单格式
      devices = Array(get(data, 'devices'))
      scripts = Array(get(data, 'scripts'))
    else
      # 分组格式：每个键是一个分组，组内是 devs / scripts
      data.each_value do |group|
        next unless group.is_a?(Hash)

        devices.concat(Array(get(group, 'devs')))
        scripts.concat(Array(get(group, 'scripts')))
      end
    end

    {
      devices: devices.uniq { |device| id_of(device) },
      scripts: scripts.uniq { |script| id_of(script) }
    }
  end

  # 剥掉 task_json 包装层，返回真正承载 devices/scripts 的那一层
  def unwrap(definition)
    return nil unless definition.is_a?(Hash)

    wrapped = get(definition, 'task_json')
    wrapped.is_a?(Hash) ? wrapped : definition
  end

  def key?(hash, name)
    hash.key?(name) || hash.key?(name.to_sym)
  end

  def get(hash, name)
    hash[name] || hash[name.to_sym]
  end

  def id_of(item)
    return item unless item.is_a?(Hash)

    item['id'] || item[:id]
  end
end

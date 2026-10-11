# frozen_string_literal: true

require 'json'

# 命令映射 JSON 的解析工具
#
# 业务逻辑：
#   主线脚本生成与分支映射生成都会拿到形如 {"commands":[{"command","response"}]} 的
#   JSON（可能包裹在 ```json 代码块里），这里统一解析成节点数组。
#
#   节点支持嵌套：命中带 children 的命令即进入下一层上下文，因此在不同上下文下，
#   同一个命令（例如 ls）可以有不同的 response。树是"仅模拟服务器使用"的结构，
#   真机与生成的脚本都不涉及。
#
# 隐性知识：
#   response 允许为空字符串（真实设备有些命令无回显），因此只做键提取，不做 present? 过滤；
#   缺 response 键时保持 nil，交由 FakeTelnetServerManager 判定为"未配置"。
#   模型偶尔会多输出解释性条目或写坏某个 children，这里对畸形节点一律跳过而不抛异常，
#   保证整份映射仍可用——生成侧最怕的是因为一个坏节点让整个测试环境没有映射。
module CommandMappingParser
  ParseError = Class.new(StandardError)

  # 解析命令映射内容，返回节点数组。
  #
  # 节点结构（symbol 键）：
  #   { command: String, response: String|nil, children: [Node], mock: { exit_level: } }
  # 平铺映射即"children 为空的根节点"，输出形状与旧版 [{command:, response:}] 兼容。
  def self.parse(mapping_content)
    return [] if mapping_content.nil? || mapping_content.to_s.strip.empty?

    content = mapping_content.to_s.gsub(/\A```json\s*/, '').gsub(/```\s*\z/, '').strip
    data = JSON.parse(content)
    # 兼容模型直接输出裸数组（少数情况下不带外层 {"commands": ...}）
    raw_commands = data.is_a?(Array) ? data : (data['commands'] || [])
    normalize_nodes(raw_commands)
  rescue JSON::ParserError => e
    raise ParseError, "命令映射 JSON 解析失败: #{e.message}"
  end

  # 递归规范化节点列表。
  #
  # 隐性知识：
  #   非 Hash 条目、缺 command 的条目、空 command 一律跳过；单个坏节点不影响同级其他节点，
  #   也不影响父节点——父节点仍会以"无该子命令"的形式注册。
  def self.normalize_nodes(raw_nodes)
    Array(raw_nodes).filter_map do |raw|
      next unless raw.is_a?(Hash)

      command = fetch(raw, 'command')
      next if command.nil? || command.to_s.empty?

      node = { command: command, response: fetch(raw, 'response') }
      mock = normalize_mock(fetch(raw, 'mock'))
      node[:mock] = mock if mock
      children = normalize_nodes(fetch(raw, 'children'))
      node[:children] = children if children.any?
      node
    end
  end

  # 规范化 mock 块（仅模拟服务器使用的导航元数据）。exit_level 允许整数或数字字符串。
  #
  # 隐性知识：
  #   mock 里**只有 exit_level**。曾经还有过 prompt（每层自定义提示符），已删除：
  #   提示符因设备而异，映射里写死会误导后续生成的脚本去依赖某个具体提示符。
  def self.normalize_mock(raw_mock)
    return nil unless raw_mock.is_a?(Hash)

    mock = {}
    exit_level = fetch(raw_mock, 'exit_level')
    if exit_level.is_a?(Integer)
      mock[:exit_level] = exit_level
    elsif exit_level.to_s.match?(/\A\d+\z/)
      mock[:exit_level] = exit_level.to_i
    end

    mock.empty? ? nil : mock
  end

  # 把映射树摊平成节点列表，供"需要所有命令"的下游使用（评估摘要、映射补充、计数）。
  #
  # 每个条目额外带 context_path（如 "root > switch board 1"），便于评估模型理解
  # 同一命令在不同上下文下的不同回显；同时兼容旧的 Hash 平铺格式。
  def self.flatten(mapping, context_path = 'root')
    case mapping
    when Array
      mapping.flat_map { |node| flatten_node(node, context_path) }
    when Hash
      # 旧格式：{ "命令" => "回显" }
      mapping.filter_map do |command, response|
        next if command.to_s.empty?

        { command: command, response: response, context_path: context_path }
      end
    else
      []
    end
  end

  def self.flatten_node(node, context_path)
    return [] unless node.is_a?(Hash)

    command = fetch(node, 'command')
    return [] if command.nil? || command.to_s.empty?

    entry = { command: command, response: fetch(node, 'response'), context_path: context_path }
    mock = fetch(node, 'mock')
    entry[:mock] = mock if mock.is_a?(Hash)
    entry_and_children = [entry]
    entry_and_children + flatten(fetch(node, 'children'), "#{context_path} > #{command}")
  end

  # 兼容 symbol / string 两种键。
  def self.fetch(hash, key)
    return nil unless hash.is_a?(Hash)

    hash.key?(key) ? hash[key] : hash[key.to_sym]
  end
  private_class_method :flatten_node
end

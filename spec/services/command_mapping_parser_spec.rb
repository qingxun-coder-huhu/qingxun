# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/command_mapping_parser'

# 命令映射解析：平铺与嵌套（上下文树）两种形态。
#
# 背景：模拟服务器支持"命中带 children 的命令即进入下一层上下文"，因此同一命令在不同
# 上下文下可以有不同的回显。解析层必须容错——模型偶尔会多输出解释性条目或写坏某个
# children，坏节点只能被跳过，不能让整份映射失效。
RSpec.describe CommandMappingParser do
  describe '.parse' do
    it '解析平铺映射，输出与旧格式兼容的节点' do
      json = '{"commands":[{"command":"show version","response":"v1"}]}'

      expect(described_class.parse(json)).to eq([{ command: 'show version', response: 'v1' }])
    end

    it '保留空字符串 response（命令无回显是合法配置）' do
      json = '{"commands":[{"command":"diagnose","response":""}]}'

      expect(described_class.parse(json).first[:response]).to eq('')
    end

    it '缺 response 键时保留 nil，交由 manager 判定未配置' do
      json = '{"commands":[{"command":"x"}]}'

      expect(described_class.parse(json).first[:response]).to be_nil
    end

    it '解析嵌套 children 与 mock 导航元数据' do
      json = <<~JSON
        {
          "commands": [
            { "command": "switch board 1", "response": "",
              "children": [
                { "command": "ls", "response": "card1" },
                { "command": "exit", "response": "", "mock": { "exit_level": 1 } }
              ] }
          ]
        }
      JSON

      node = described_class.parse(json).first
      expect(node[:command]).to eq('switch board 1')
      expect(node[:mock]).to be_nil
      expect(node[:children].map { |c| c[:command] }).to eq(%w[ls exit])
      expect(node[:children].last[:mock]).to eq(exit_level: 1)
    end

    # 提示符因设备而异，映射里不该有它：mock.prompt 已被删除，
    # 旧数据/模型残留该字段时直接忽略，不能让它漏进节点
    it '忽略 mock 里残留的 prompt 字段（该字段已删除）' do
      json = '{"commands":[{"command":"ls","response":"a","mock":{"prompt":"board1> ","exit_level":1}}]}'

      expect(described_class.parse(json).first[:mock]).to eq(exit_level: 1)
    end

    it '把数字字符串形式的 exit_level 规范化为整数' do
      json = '{"commands":[{"command":"exit","response":"","mock":{"exit_level":"0"}}]}'

      expect(described_class.parse(json).first[:mock]).to eq(exit_level: 0)
    end

    it '剥离 ```json 代码块标记' do
      json = "```json\n{\"commands\":[{\"command\":\"ls\",\"response\":\"a\"}]}\n```"

      expect(described_class.parse(json).first[:command]).to eq('ls')
    end

    it '兼容模型直接输出裸数组' do
      json = '[{"command":"ls","response":"a"}]'

      expect(described_class.parse(json).first[:command]).to eq('ls')
    end

    it '跳过畸形子节点，不影响同级其他节点' do
      json = <<~JSON
        {
          "commands": [
            "解释性文字",
            { "response": "缺 command" },
            { "command": "", "response": "空 command" },
            { "command": "ls", "response": "a",
              "children": [ { "command": "bad", "response": "ok" }, "再次解释" ] }
          ]
        }
      JSON

      nodes = described_class.parse(json)
      expect(nodes.map { |n| n[:command] }).to eq(['ls'])
      expect(nodes.first[:children].map { |n| n[:command] }).to eq(['bad'])
    end

    it '空输入返回空数组' do
      expect(described_class.parse(nil)).to eq([])
      expect(described_class.parse('  ')).to eq([])
    end

    it 'JSON 非法时抛 ParseError' do
      expect { described_class.parse('{not json') }.to raise_error(described_class::ParseError)
    end
  end

  describe '.flatten' do
    let(:mapping) do
      [
        { command: 'show version', response: 'v1' },
        { command: 'switch board 1', response: '',
          children: [
            { command: 'ls', response: 'card1' },
            { command: 'cd card2', response: '',
              children: [{ command: 'ls', response: 'port1' }] }
          ] }
      ]
    end

    it '摊平嵌套树并带上下文路径' do
      entries = described_class.flatten(mapping)

      expect(entries.map { |e| e[:command] }).to eq(['show version', 'switch board 1', 'ls', 'cd card2', 'ls'])
      expect(entries.map { |e| e[:context_path] }).to eq([
        'root',
        'root',
        'root > switch board 1',
        'root > switch board 1',
        'root > switch board 1 > cd card2'
      ])
    end

    it '同名命令在不同上下文下各保留一条（回显不同）' do
      entries = described_class.flatten(mapping).select { |e| e[:command] == 'ls' }

      expect(entries.size).to eq(2)
      expect(entries.map { |e| e[:response] }).to eq(%w[card1 port1])
    end

    it '兼容旧的 Hash 平铺格式' do
      expect(described_class.flatten({ 'show version' => 'v1' })).to eq(
        [{ command: 'show version', response: 'v1', context_path: 'root' }]
      )
    end

    it '非数组/哈希输入返回空数组' do
      expect(described_class.flatten(nil)).to eq([])
      expect(described_class.flatten('x')).to eq([])
    end
  end
end

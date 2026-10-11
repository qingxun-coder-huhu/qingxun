# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'

# 加载被测试的服务
require_relative '../../app/services/debug_session'

RSpec.describe DebugSession do
  # 测试使用的临时端口，避免与默认端口 2323 冲突
  let(:test_port) { 23998 }
  # 模拟的 Rails 模块，提供 Rails.root 和 Rails.logger
  let(:rails_mock) do
    double('Rails',
           root: Pathname.new(Dir.mktmpdir('debug_session_test')),
           logger: double('Logger', error: nil, info: nil, warn: nil, debug: nil))
  end

  before do
    # 模拟 Rails 常量，防止 DebugSession 因缺少 Rails 而崩溃
    stub_const('Rails', rails_mock)
    # 确保临时目录存在
    FileUtils.mkdir_p(Rails.root.join('tmp', 'debug_scripts'))
  end

  after do
    # 清理临时目录
    FileUtils.rm_rf(Rails.root) if Rails.root.exist?
  end

  # 生成的脚本代码：等价于 AI 针对"查看 display vlan"需求产出的脚本，
  # 继承 Qingxun::DeviceScript，下发 display vlan 并从回显里解析 VLAN ID。
  let(:generated_script_code) do
    <<~RUBY
      class GeneratedDisplayVlanScript < Qingxun::DeviceScript
        def run(connection)
          log_info "开始执行 display vlan 命令"
          output = connection.cli('display vlan')
          vlan_ids = output.scan(/VLAN ID:\\s*(\\d+)/).flatten.map(&:to_i)
          { command: 'display vlan', vlan_ids: vlan_ids }
        end
      end
    RUBY
  end

  # 命令映射：DebugSession 消费的是数组结构（不是文件路径），
  # 模拟服务器据此回显 display vlan 的输出。
  let(:command_mapping) do
    [
      {
        'command' => 'display vlan',
        'response' => "VLAN ID: 1\nVLAN ID: 2\nVLAN ID: 10\nVLAN ID: 100"
      }
    ]
  end

  describe '#run' do
    it '成功执行生成的display vlan脚本并返回结构化结果' do
      # 创建 DebugSession 实例，传入脚本代码、命令映射和测试端口
      session = described_class.new(generated_script_code, nil, command_mapping, test_port)

      # 执行调试会话
      result = session.run

      # 验证结果结构
      expect(result).to be_a(Hash)
      expect(result[:success]).to be true
      expect(result[:error]).to be_nil
      expect(result[:logs]).to be_an(Array)
      expect(result[:logs]).not_to be_empty

      # 验证脚本返回值
      expect(result[:result]).to be_a(Hash)
      expect(result[:result][:command]).to eq('display vlan')
      expect(result[:result][:vlan_ids]).to eq([1, 2, 10, 100])

      # 验证日志中是否包含脚本记录的日志
      expect(result[:logs].any? { |log| log.include?('开始执行 display vlan 命令') }).to be true
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BranchMappingGenerationService do
  let(:code) { "module QingxunScript\n  class X < Qingxun::DeviceScript\n  end\nend" }
  let(:branch_description) { '设备返回命令错误回显' }

  describe '#call' do
    it '解析模型返回的 json 代码块为命令映射' do
      content = <<~CONTENT
        这是该分支的命令映射：
        ```json
        { "commands": [ { "command": "show version", "response": "Error: invalid input" } ] }
        ```
      CONTENT
      allow(LlmRequestService).to receive(:call).and_return(
        'choices' => [{ 'message' => { 'content' => content } }]
      )

      result = described_class.new(code, branch_description, mainline_description: '主线').call

      expect(result[:error]).to be_nil
      expect(result[:command_mapping]).to eq([{ command: 'show version', response: 'Error: invalid input' }])
    end

    it 'LLM 调用失败时降级为 error，不抛异常' do
      allow(LlmRequestService).to receive(:call).and_raise(StandardError, 'boom')

      result = described_class.new(code, branch_description).call

      expect(result[:command_mapping]).to eq([])
      expect(result[:error]).to include('boom')
    end

    it '分支描述为空时直接返回错误，不调用 LLM' do
      expect(LlmRequestService).not_to receive(:call)

      result = described_class.new(code, '  ').call

      expect(result[:command_mapping]).to eq([])
      expect(result[:error]).to include('分支描述为空')
    end

    it '提示词要求原样采用分支描述里已给出的命令与报文' do
      prompt = Prompts::BranchMapping.build(code, "命令 show boot\n报文\nBootRom Version: 1.0", '主线')

      expect(prompt).to include('原样采用')
      expect(prompt).to include('show boot')
    end

    # 转义成 `\#{` 后，模型看到的是被改过的代码（评估侧已因此提过 21 条假问题）
    it '脚本代码原样进提示词，不做插值转义' do
      prompt = Prompts::BranchMapping.build('log_info("#{list}")', '分支描述', '主线')

      expect(prompt).to include('log_info("#{list}")')
      expect(prompt).not_to include('\#{list}')
    end
  end

  describe '主线变体（scenario_kind: :main）' do
    it '使用中性主线提示词与 mainline system prompt，仍然只产出映射' do
      captured = nil
      allow(LlmRequestService).to receive(:call) do |messages:, step_name:, **|
        captured = { user: messages.last[:content], system: messages.first[:content], step: step_name }
        { 'choices' => [{ 'message' => { 'content' => "```json\n{\"commands\":[{\"command\":\"display version\",\"response\":\"V1\"}]}\n```" } }] }
      end

      result = described_class.new(code, '主线需求描述', scenario_kind: :main).call

      expect(result[:error]).to be_nil
      expect(result[:command_mapping]).to eq([{ command: 'display version', response: 'V1' }])
      expect(captured[:user]).to include('主线场景')
      expect(captured[:user]).not_to include('分支测试场景')
      expect(captured[:step]).to eq('generate_mainline')
      expect(captured[:system]).to include('不能')
    end

    it '主线描述为空时给出中性错误，不调用 LLM' do
      expect(LlmRequestService).not_to receive(:call)

      result = described_class.new(code, '   ', scenario_kind: :main).call

      expect(result[:command_mapping]).to eq([])
      expect(result[:error]).to include('主线描述为空')
    end

    it 'prompt 直接可断言：中性措辞且禁改代码' do
      prompt = Prompts::BranchMapping.build_mainline(code, '主线描述')

      expect(prompt).to include('主线场景')
      expect(prompt).not_to include('分支测试场景')
      expect(prompt).to include(code)
      expect(Prompts::BranchMapping.mainline_system_prompt).to include('不能')
    end

    it '不传 kind 时默认仍是分支提示词与 step（行为不变）' do
      captured = nil
      allow(LlmRequestService).to receive(:call) do |messages:, step_name:, **|
        captured = { user: messages.last[:content], step: step_name }
        { 'choices' => [{ 'message' => { 'content' => '{"commands":[]}' } }] }
      end

      described_class.new(code, branch_description, mainline_description: '主线').call

      expect(captured[:user]).to include('分支测试场景')
      expect(captured[:step]).to eq('generate')
    end
  end
end

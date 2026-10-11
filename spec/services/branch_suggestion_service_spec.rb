# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BranchSuggestionService do
  let(:mainline) { '巡检交换机并检查 CPU 利用率' }

  def llm_returning(content)
    allow(LlmRequestService).to receive(:call).and_return(
      'choices' => [{ 'message' => { 'content' => content } }]
    )
  end

  # 一致性校验默认"全部合规"：这些用例只关心建议生成本身，
  # 避免它额外消耗一次 LLM 调用。需要时在具体用例里覆盖。
  def stub_consistency_ok
    allow(BranchConsistencyService).to receive(:new) do |_description, branches|
      results = Array(branches).each_with_index.map do |branch, index|
        { index: index, name: branch[:name], verdict: 'ok', reason: '', offending: [] }
      end
      instance_double(BranchConsistencyService, call: { success: true, results: results, has_issues: false, error: nil })
    end
  end

  before { stub_consistency_ok }

  describe '#call' do
    it '解析出建议分支（名称 + 全量描述）' do
      llm_returning(<<~CONTENT)
        ```json
        { "branches": [
          { "name": "命令报错", "description": "设备对巡检命令返回错误回显时的完整场景" },
          { "name": "CPU 过高", "description": "CPU 利用率超过阈值时的完整场景" }
        ] }
        ```
      CONTENT

      result = described_class.new(mainline).call

      expect(result[:success]).to be true
      expect(result[:branches].size).to eq(2)
      expect(result[:branches].first[:name]).to eq('命令报错')
      expect(result[:branches].first[:description]).to include('错误回显')
    end

    it '模型多给建议时只取前 3 条' do
      branches = (1..5).map { |i| { name: "分支#{i}", description: "场景#{i}" } }
      llm_returning({ branches: branches }.to_json)

      result = described_class.new(mainline).call

      expect(result[:success]).to be true
      expect(result[:branches].size).to eq(3)
    end

    it '丢掉没有描述的建议' do
      llm_returning({ branches: [{ name: '空', description: '' }, { name: '有效', description: '有描述' }] }.to_json)

      result = described_class.new(mainline).call

      expect(result[:branches].map { |b| b[:name] }).to eq(['有效'])
    end

    it 'LLM 调用失败时返回 success:false，不抛异常' do
      allow(LlmRequestService).to receive(:call).and_raise(StandardError, 'boom')

      result = described_class.new(mainline).call

      expect(result[:success]).to be false
      expect(result[:branches]).to eq([])
      expect(result[:error]).to include('boom')
    end

    it '主线描述为空时直接返回错误' do
      expect(LlmRequestService).not_to receive(:call)

      result = described_class.new('   ').call

      expect(result[:success]).to be false
      expect(result[:error]).to include('主线描述不能为空')
    end

    it '换一批：把上一批建议作为 avoid 带进提示词，要求不要重复' do
      captured_prompt = nil
      allow(LlmRequestService).to receive(:call) do |messages:, **|
        captured_prompt = messages.last[:content]
        { 'choices' => [{ 'message' => { 'content' => '{"branches":[]}' } }] }
      end

      described_class.new('巡检交换机', avoid_branches: [{ name: '旧建议', description: '旧的场景描述' }]).call

      expect(captured_prompt).to include('上一批已经给过')
      expect(captured_prompt).to include('旧建议')
    end

    it '丢弃超纲/矛盾的建议，只保留合规的' do
      llm_returning({ branches: [
        { name: '合规分支', description: '命令 display fan' },
        { name: '超纲分支', description: 'Base 命令返回 %Error 要判失败并结束' }
      ] }.to_json)
      allow(BranchConsistencyService).to receive(:new).and_return(instance_double(BranchConsistencyService, call: {
        success: true, has_issues: true, error: nil,
        results: [
          { index: 0, name: '合规分支', verdict: 'ok', reason: '在主线范围内', offending: [] },
          { index: 1, name: '超纲分支', verdict: 'stricter', reason: '主线未声明该命令的 %Error 处理', offending: ['新增失败处理'] }
        ]
      }))

      result = described_class.new(mainline).call

      expect(result[:success]).to be true
      expect(result[:branches].map { |b| b[:name] }).to eq(['合规分支'])
      expect(result[:dropped].first).to include(name: '超纲分支', verdict: 'stricter')
      expect(result[:consistency_checked]).to be true
    end

    it '建议全部不合规时返回 success:false，并带上被丢弃的建议与原因' do
      llm_returning({ branches: [{ name: '超纲分支', description: 'd1' }] }.to_json)
      allow(BranchConsistencyService).to receive(:new).and_return(instance_double(BranchConsistencyService, call: {
        success: true, has_issues: true, error: nil,
        results: [{ index: 0, name: '超纲分支', verdict: 'contradiction', reason: '与主线结论冲突', offending: [] }]
      }))

      result = described_class.new(mainline).call

      expect(result[:success]).to be false
      expect(result[:branches]).to eq([])
      expect(result[:dropped].size).to eq(1)
      expect(result[:error]).to include('超出主线要求')
    end

    it '一致性校验服务失败时 fail-open：保留建议并标记未校验' do
      llm_returning({ branches: [{ name: '分支1', description: 'd1' }] }.to_json)
      allow(BranchConsistencyService).to receive(:new).and_return(
        instance_double(BranchConsistencyService, call: { success: false, results: [], has_issues: false, error: 'boom' })
      )

      result = described_class.new(mainline).call

      expect(result[:success]).to be true
      expect(result[:branches].size).to eq(1)
      expect(result[:consistency_checked]).to be false
      expect(result[:dropped]).to eq([])
    end
  end

  describe '自定义场景（custom_requirement）' do
    it '把用户场景写进提示词，并按用户描述生成（只有一条就只给一条，不凑数）' do
      captured = nil
      allow(LlmRequestService).to receive(:call) do |messages:, step_name:, **|
        captured = { user: messages.last[:content], system: messages.first[:content], step: step_name }
        { 'choices' => [{ 'message' => { 'content' => { branches: [{ name: '权限不足', description: '只这一条' }] }.to_json } }] }
      end

      result = described_class.new(mainline, custom_requirement: '设备返回权限不足').call

      expect(result[:success]).to be true
      expect(result[:branches].size).to eq(1)
      expect(captured[:user]).to include('设备返回权限不足')
      expect(captured[:user]).to include('条数由用户描述决定')
      expect(captured[:system]).to include('不要为了凑成固定条数')
      expect(captured[:step]).to eq('suggest_custom')
    end

    it '模型多给时最多取 5 条（自定义上限）' do
      branches = (1..8).map { |i| { name: "分支#{i}", description: "场景#{i}" } }
      llm_returning({ branches: branches }.to_json)

      result = described_class.new(mainline, custom_requirement: '覆盖多种异常').call

      expect(result[:success]).to be true
      expect(result[:branches].size).to eq(5)
    end

    it '给不出有效分支时，错误提示让用户把场景写具体些' do
      llm_returning('{"branches":[]}')

      result = described_class.new(mainline, custom_requirement: '随便').call

      expect(result[:success]).to be false
      expect(result[:error]).to include('更具体')
    end

    it '未传自定义时仍走默认路径（提示词要求恰好 3 条）' do
      captured = nil
      allow(LlmRequestService).to receive(:call) do |messages:, **|
        captured = messages.last[:content]
        { 'choices' => [{ 'message' => { 'content' => '{"branches":[]}' } }] }
      end

      described_class.new(mainline).call

      expect(captured).to include('恰好 3 条')
    end
  end

  describe '提示词风格约束' do
    it '要求分支描述与主线同风格：命令 / 报文 / 处理逻辑' do
      prompt = Prompts::BranchSuggestion.build('命令 display cpu-usage\n报文\nCPU 20%\n处理逻辑：小于 80%')

      expect(prompt).to include('同一种风格')
      expect(prompt).to include('命令 / 报文 / 处理逻辑')
      expect(prompt).to include('报文')
    end

    it '明确禁止占位步骤与元信息说明' do
      system_prompt = Prompts::BranchSuggestion.system_prompt

      expect(system_prompt).to include('禁止列出不会执行的命令')
      expect(system_prompt).to include('（不执行）')
      expect(system_prompt).to include('命令 / 报文 / 处理逻辑')
    end

    it '只写实际执行的步骤，不列未执行命令、不写占位与场景前提' do
      prompt = Prompts::BranchSuggestion.build('命令 display cpu-usage\n报文\nCPU 20%')

      expect(prompt).to include('实际会执行')
      expect(prompt).to include('不要列出不会执行的命令')
      expect(prompt).to include('（不执行）')
      expect(prompt).to include('其余同主线')
      expect(prompt).to include('场景前提')
    end

    it 'system prompt 同样约束只写实际执行步骤' do
      system_prompt = Prompts::BranchSuggestion.system_prompt

      expect(system_prompt).to include('实际执行流程')
      expect(system_prompt).to include('禁止列出不会执行的命令')
    end

    it 'build 支持 avoid 参数，提示换一批不要重复' do
      prompt = Prompts::BranchSuggestion.build('主线', [], [{ name: '旧建议', description: '旧场景' }])

      expect(prompt).to include('上一批已经给过')
      expect(prompt).to include('换一批')
      expect(prompt).to include('旧建议')
    end

    it '要求分支不得超出主线（不得引入主线未声明的规则）' do
      prompt = Prompts::BranchSuggestion.build('主线需求')
      system_prompt = Prompts::BranchSuggestion.system_prompt

      expect(prompt).to include('不得超出主线')
      expect(prompt).to include('主线未声明')
      expect(prompt).to include('规则跟着它所在的命令走')
      expect(system_prompt).to include('不得超出主线')
      expect(system_prompt).to include('主线未声明')
    end
  end
end

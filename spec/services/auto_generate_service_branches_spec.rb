# frozen_string_literal: true

require 'rails_helper'

# 分支覆盖：主线 + 全部分支都通过才算成功；分支只做测试，代码仍按主线生成
RSpec.describe AutoGenerateService, '分支覆盖' do
  let(:branches) { [{ name: '命令报错', description: '设备对巡检命令返回错误回显的完整场景' }] }
  let(:code) { "module QingxunScript\n  class X < Qingxun::DeviceScript\n  end\nend" }
  let(:passed_eval) do
    { passed: true, evaluation: '通过', items: [], issues: [], suggestions: [],
      env_mismatches: [], mapping_suggestions: [], user_questions: [] }
  end
  let(:failed_eval) do
    { passed: false, evaluation: '分支失败', items: [{ requirement: '错误回显处理', passed: false, attribution: 'script_issue' }],
      issues: ['未处理错误回显'], suggestions: [], env_mismatches: [], mapping_suggestions: [], user_questions: [] }
  end

  def stub_generation(service)
    allow(service).to receive(:generate_script).and_return(
      code: code, command_mapping: [{ command: 'show version', response: 'ok' }], script_name: 'x', description: 'd'
    )
  end

  def stub_branch_mapping
    allow(BranchMappingGenerationService).to receive(:new).and_return(
      instance_double(BranchMappingGenerationService, call: { command_mapping: [{ command: 'show version', response: 'err' }], error: nil })
    )
  end

  it '主线通过即成功，并返回主线与各分支的结果' do
    service = described_class.new('主线描述', branches: branches)
    stub_generation(service)
    stub_branch_mapping
    allow(service).to receive(:run_test).and_return({ success: true, logs: [], result: {} })
    allow(service).to receive(:evaluate_result).and_return(passed_eval)

    result = service.call

    expect(result[:success]).to be true
    expect(result[:scenarios].size).to eq(2)
    expect(result[:scenarios].map { |s| s[:kind] }).to eq(%w[main branch])
    expect(result[:branch_scenarios].size).to eq(1)
    expect(result[:branch_scenarios].first).to include(name: '命令报错', passed: true)
    expect(result[:branch_summary]).to eq(total: 1, passed: 1)
  end

  it '为主线通过后的每个分支生成命令映射并逐个测试' do
    service = described_class.new('主线描述', branches: branches)
    stub_generation(service)
    stub_branch_mapping
    allow(service).to receive(:run_test).and_return({ success: true, logs: [], result: {} })
    allow(service).to receive(:evaluate_result).and_return(passed_eval)

    stages = []
    service.call { |progress| stages << progress[:stage] }

    expect(stages).to include(:scenario_mapping_generating, :scenario_mapping_generated, :scenario_testing, :scenario_evaluated)
    # success（主线通过）必须早于分支执行事件
    expect(stages.index(:success)).to be < stages.index(:scenario_mapping_generating)
  end

  # 分支结果只用于告知：不参与通过判定，也不回流到下一轮代码生成。
  it '分支失败不影响主线成功，也不触发重试' do
    service = described_class.new('主线描述', branches: branches)
    stub_branch_mapping
    feedbacks = []
    allow(service).to receive(:generate_script) do |feedback|
      feedbacks << feedback
      { code: code, command_mapping: [], script_name: 'x', description: 'd' }
    end
    allow(service).to receive(:run_test).and_return({ success: true, logs: [], result: {} })
    allow(service).to receive(:evaluate_result) do |description, *|
      description == '主线描述' ? passed_eval : failed_eval
    end

    result = service.call

    expect(result[:success]).to be true
    expect(result[:attempts]).to eq(1)
    expect(feedbacks.size).to eq(1)
    expect(result[:branch_summary]).to eq(total: 1, passed: 0)
    expect(result[:branch_scenarios].first[:passed]).to be false
  end

  # 主线不通过时，既不判定成功，也不执行（更不会因分支而重试）。
  it '主线未通过时不执行分支，并按主线失败重试' do
    service = described_class.new('主线描述', branches: branches)
    stub_generation(service)
    allow(service).to receive(:run_test).and_return({ success: true, logs: [], result: {} })
    allow(service).to receive(:evaluate_result).and_return(failed_eval)
    allow(service).to receive(:get_final_suggestion).and_return('请补充主线描述')
    expect(BranchMappingGenerationService).not_to receive(:new)

    result = service.call

    expect(result[:success]).to be false
    expect(result[:attempts]).to eq(3)
    expect(result[:branch_scenarios]).to eq([])
    expect(result[:final_suggestion]).to eq('请补充主线描述')
  end

  it '没有分支时行为与主线单场景一致' do
    service = described_class.new('主线描述')
    stub_generation(service)
    allow(service).to receive(:run_test).and_return({ success: true, logs: [], result: {} })
    allow(service).to receive(:evaluate_result).and_return(passed_eval)

    expect(BranchMappingGenerationService).not_to receive(:new)

    result = service.call

    expect(result[:success]).to be true
    expect(result[:scenarios].size).to eq(1)
    expect(result[:branch_scenarios]).to eq([])
  end

  it '丢弃没有描述的分支' do
    service = described_class.new('主线描述', branches: [{ name: '空分支', description: '  ' }])
    stub_generation(service)
    allow(service).to receive(:run_test).and_return({ success: true, logs: [], result: {} })
    allow(service).to receive(:evaluate_result).and_return(passed_eval)

    result = service.call

    expect(result[:scenarios].size).to eq(1)
    expect(result[:branch_scenarios]).to eq([])
  end

  it '微调模式：把现有代码与分支描述传给生成服务' do
    service = described_class.new('主线描述', branches: branches, base_code: 'module QingxunScript; class Old; end; end',
                                  script_uid: 'deadbeefdeadbeef')
    captured = nil
    generation_double = instance_double(
      ScriptGenerationService,
      call: { code: code, command_mapping: [], script_name: 'x', description: 'd' }
    )
    allow(ScriptGenerationService).to receive(:new) do |*args, **kwargs|
      captured = { args: args, kwargs: kwargs }
      generation_double
    end
    stub_branch_mapping
    allow(service).to receive(:run_test).and_return({ success: true, logs: [], result: {} })
    allow(service).to receive(:evaluate_result).and_return(passed_eval)

    result = service.call

    expect(captured[:kwargs][:existing_code]).to eq('module QingxunScript; class Old; end; end')
    expect(captured[:kwargs][:branches].size).to eq(1)
    expect(captured[:kwargs][:script_uid]).to eq('deadbeefdeadbeef')
    expect(result[:success]).to be true
  end
end

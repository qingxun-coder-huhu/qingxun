# frozen_string_literal: true

require 'rails_helper'

# 评估失败后回流给下一轮生成的反馈，必须按**条目**组织
#
# 背景：早先把 issues/suggestions 拼成一坨散文，下一轮生成无法"哪条不过改哪条"；
# 而且环境问题与脚本问题混在一起，AI 会去改脚本适配错误的 mock 回显。
#
# 分支覆盖改造后，反馈按「场景」组织：主线与每个分支各自成段，映射粘性状态也按
# 场景分桶；这里沿用主线场景覆盖原有行为。
RSpec.describe AutoGenerateService, '失败反馈构建' do
  subject(:service) { described_class.new('占位描述') }

  # 把一份评估结果包成场景（默认主线），供按场景组织的新接口使用
  def scenario_for(evaluation, key: 'main', kind: :main, name: '主线', test_result: {})
    { key: key, kind: kind, name: name, evaluation: evaluation, test_result: test_result }
  end

  let(:evaluation) do
    {
      evaluation: '两条未通过',
      items: [
        { requirement: '下发 diagnose 进入诊断模式', passed: false, expected: '进入诊断模式',
          observed: '回 not recognized', evidence: 'Command diagnose not recognized.', attribution: 'env_mismatch', note: '映射为空' },
        { requirement: '已通过的条目应正常记录', passed: true, expected: 'ok', observed: 'ok',
          evidence: 'ok', attribution: 'ok', note: '' },
        { requirement: '统计失败条数并上报 pass/major', passed: false, expected: '上报状态',
          observed: '未实现', evidence: '日志无 pass/major', attribution: 'script_issue', note: '' }
      ],
      env_mismatches: ['diagnose 映射为空但执行回 not recognized'],
      issues: ['未上报状态'],
      suggestions: ['补充结果上报']
    }
  end

  it '逐条列出未达成的条目，含期望/实际/证据/归因' do
    text = service.send(:build_error_history, [scenario_for(evaluation)])

    expect(text).to include('未达成的需求条目')
    expect(text).to include('下发 diagnose 进入诊断模式')
    expect(text).to include('统计失败条数并上报 pass/major')
    expect(text).to include('归因: env_mismatch')
    expect(text).to include('Command diagnose not recognized.')
  end

  it '不把已通过的条目混进失败反馈' do
    text = service.send(:build_error_history, [scenario_for(evaluation)])

    expect(text).not_to include('已通过的条目应正常记录')
  end

  it '单独标注环境/映射问题，并明确不要靠改脚本去迁就' do
    text = service.send(:build_error_history, [scenario_for(evaluation)])

    expect(text).to include('不要靠改脚本去迁就')
    expect(text).to include('diagnose 映射为空但执行回 not recognized')
  end

  it '分支场景的失败反馈带场景名，便于回流到代码生成' do
    text = service.send(:build_error_history, [
      scenario_for(evaluation, key: 'branch:0', kind: :branch, name: '命令报错')
    ])

    expect(text).to include('分支场景【命令报错】')
    expect(text).to include('下发 diagnose 进入诊断模式')
  end

  describe '命令映射补充的跟踪与披露' do
    let(:mapping_eval) do
      {
        evaluation: '映射缺失',
        items: [],
        env_mismatches: ['diag shell PFU-0/0/0 无映射'],
        issues: [],
        suggestions: [],
        mapping_suggestions: [
          { command: 'diag shell PFU-0/0/0', issue: '映射缺失',
            suggested_response: '', reason: '需求写明该命令收到空字符串' }
        ]
      }
    end

    it '把待补命令带进下一轮的失败反馈（第二轮据此生成映射）' do
      service.send(:collect_mapping_suggestions, 'main', mapping_eval, 1)
      text = service.send(:build_error_history, [scenario_for(mapping_eval)])

      expect(text).to include('必须出现在本次生成的命令映射中')
      expect(text).to include('diag shell PFU-0/0/0')
      expect(text).to include('建议报文')
      expect(text).to include('缺失，需补齐')
    end

    it '新一代映射带上该命令后，记为已补充并生成披露文案' do
      service.send(:collect_mapping_suggestions, 'main', mapping_eval, 1)
      service.send(:reconcile_mapping_supplements, 'main', [{ command: 'diag shell PFU-0/0/0', response: '' }], 2)

      expect(service.instance_variable_get(:@mapping_supplements)['main'].size).to eq(1)
      notice = service.send(:mapping_supplement_notice)
      expect(notice).to include('自动补充')
      expect(notice).to include('diag shell PFU-0/0/0')
      expect(notice).to include('第 2 轮补齐')
    end

    # 这是实测踩到的回退：第2轮补上了映射，第3轮评估没再提，重新生成时又被丢掉。
    it '补齐过的映射在后续轮次仍被要求保留（粘性，防回退）' do
      service.send(:collect_mapping_suggestions, 'main', mapping_eval, 1)
      service.send(:reconcile_mapping_supplements, 'main', [{ command: 'diag shell PFU-0/0/0', response: '' }], 2)

      empty_eval = { evaluation: 'x', items: [], env_mismatches: [], issues: [], suggestions: [], mapping_suggestions: [] }
      text = service.send(:build_error_history, [scenario_for(empty_eval)])

      expect(text).to include('diag shell PFU-0/0/0')
      expect(text).to include('已存在，必须保留')
    end

    it '某轮生成把已补齐的映射丢掉时，重新标为缺失' do
      service.send(:collect_mapping_suggestions, 'main', mapping_eval, 1)
      service.send(:reconcile_mapping_supplements, 'main', [{ command: 'diag shell PFU-0/0/0', response: '' }], 2)
      # 下一轮映射里又没了
      service.send(:reconcile_mapping_supplements, 'main', [{ command: 'other', response: 'x' }], 3)

      pending = service.instance_variable_get(:@pending_mapping_suggestions).values.flatten.map { |s| s[:command] }
      expect(pending).to include('diag shell PFU-0/0/0')

      text = service.send(:build_error_history, [scenario_for({ evaluation: 'x', items: [], env_mismatches: [], issues: [], suggestions: [], mapping_suggestions: [] })])
      expect(text).to include('缺失，需补齐')
    end

    it '没补上时不谎报已补充' do
      service.send(:collect_mapping_suggestions, 'main', mapping_eval, 1)
      service.send(:reconcile_mapping_supplements, 'main', [{ command: 'other', response: 'x' }], 2)

      expect(service.instance_variable_get(:@mapping_supplements).values.flatten).to be_empty
      expect(service.send(:mapping_supplement_notice)).to be_nil
    end
  end

  describe '失败原因的可展示性' do
    # 页面靠 :evaluated 事件渲染失败原因；服务端曾漏发该事件，
    # 导致失败时页面只有"生成失败"标题、看不到任何原因。
    it '每轮评估后都会发出 evaluated 事件' do
      service = described_class.new('占位描述')
      allow(service).to receive(:generate_script)
        .and_return({ code: 'x', command_mapping: [], script_name: 's', description: 'd' })
      allow(service).to receive(:run_test).and_return({ success: true, result: {}, logs: [] })
      allow(service).to receive(:evaluate_result)
        .and_return({ passed: false, evaluation: 'e', items: [], issues: [], suggestions: [], mapping_suggestions: [] })
      allow(service).to receive(:get_final_suggestion).and_return('兜底')

      stages = []
      service.call { |progress| stages << progress[:stage] }

      expect(stages).to include(:evaluated)
    end

    # 最终建议的 LLM 调用失败时，不能把失败原因一起吞掉
    it '最终建议生成失败时用最后一轮评估结论兜底' do
      service = described_class.new('占位描述')
      service.instance_variable_set(:@attempt_history, [
        {
          status: :completed, attempt: 1,
          data: {
            scenarios: [
              {
                key: 'main', kind: :main, name: '主线', passed: false, test_result: {},
                evaluation: {
                  evaluation: '整体流程对，但字段不全',
                  items: [{ requirement: '补齐日志字段', passed: false, expected: '10 项', observed: '8 项', attribution: 'script_issue' }],
                  issues: ['缺少进程id'], suggestions: ['补上进程id']
                }
              }
            ]
          }
        }
      ])

      text = service.send(:fallback_final_suggestion)

      expect(text).to include('整体流程对，但字段不全')
      expect(text).to include('补齐日志字段')
      expect(text).to include('缺少进程id')
    end
  end

  describe '需要用户确认的问题' do
    let(:eval_with_question) do
      {
        passed: false,
        evaluation: '依赖用户信息',
        items: [{ requirement: '记录网元名称', passed: false, attribution: 'needs_user_confirmation',
                  expected: '真实名称', observed: '填了默认网络' }],
        issues: [], suggestions: [], env_mismatches: [], mapping_suggestions: [],
        user_questions: ['网元名称从哪里获取？']
      }
    end

    it '收集评估给出的问题；没有给出问题时用条目兜底生成' do
      service = described_class.new('占位描述')
      service.send(:collect_user_questions_and_suggestions, [scenario_for(eval_with_question)], 1)
      expect(service.instance_variable_get(:@user_questions)).to include('网元名称从哪里获取？')

      service.instance_variable_set(:@user_questions, [])
      service.send(:collect_user_questions_and_suggestions, [scenario_for(eval_with_question.merge(user_questions: []))], 1)
      expect(service.instance_variable_get(:@user_questions).any? { |q| q.include?('记录网元名称') }).to be true
    end

    it '只剩 needs_user_confirmation、没有可修复项时，判定为需用户确认' do
      service = described_class.new('占位描述')
      expect(service.send(:needs_user_confirmation_only?, [scenario_for(eval_with_question)])).to be true
    end

    it '仍有 script_issue 时不提前停轮（先把能修的修掉）' do
      service = described_class.new('占位描述')
      mixed = eval_with_question.merge(
        items: eval_with_question[:items] + [{ requirement: 'x', passed: false, attribution: 'script_issue' }]
      )
      expect(service.send(:needs_user_confirmation_only?, [scenario_for(mixed)])).to be false
    end

    # 实测坑：模型一边把失败归因成 script_issue/env_mismatch，一边又抛出 4 个"需要确认"的
    # 问题（其中不少是需求里已写明、或本次描述范围之外的），页面于是显示误导性的确认框。
    it '失败归因不是 needs_user_confirmation 时，不采纳模型抛出的问题' do
      service = described_class.new('占位描述')
      eval_script_issue = {
        passed: false,
        evaluation: '脚本问题',
        items: [{ requirement: 'X', passed: false, attribution: 'script_issue' }],
        issues: [], suggestions: [], env_mismatches: [], mapping_suggestions: [],
        user_questions: ['需求里已给的 olleh 回显格式是什么？', 'show boot 的报文格式是什么？']
      }

      service.send(:collect_user_questions_and_suggestions, [scenario_for(eval_script_issue)], 1)

      expect(service.instance_variable_get(:@user_questions)).to eq([])
    end

    it '每轮重置：上一轮的问题不会残留到本轮' do
      service = described_class.new('占位描述')
      service.instance_variable_set(:@user_questions, ['上一轮的问题'])
      ok_eval = { passed: true, evaluation: 'ok', items: [], issues: [], suggestions: [],
                  env_mismatches: [], mapping_suggestions: [], user_questions: [] }

      service.send(:collect_user_questions_and_suggestions, [scenario_for(ok_eval)], 2)

      expect(service.instance_variable_get(:@user_questions)).to eq([])
    end

    it '提前停轮的结果带问题、判为失败，不谎报成功' do
      service = described_class.new('占位描述')
      service.send(:collect_user_questions_and_suggestions, [scenario_for(eval_with_question)], 1)
      generation = { code: 'x', command_mapping: [], script_name: 's', description: 'd' }
      result = service.send(:build_clarification_result, generation, [scenario_for(eval_with_question)], 1)

      expect(result[:success]).to be false
      expect(result[:needs_user_confirmation]).to be true
      expect(result[:user_questions]).to include('网元名称从哪里获取？')
      expect(result[:final_suggestion]).to include('需要您先确认')
    end
  end
end

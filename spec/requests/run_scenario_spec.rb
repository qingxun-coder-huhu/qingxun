# frozen_string_literal: true

require 'rails_helper'

# 单场景「运行」接口
#
# 这里钉住的契约：
#   1. 需要登录（会写调试临时文件、消耗 LLM）；
#   2. **绝不重新生成或修改脚本代码**：code 原样透传给映射生成与 DebugSession；
#   3. 主线走 mainline 映射分支，分支带上主线描述作背景；
#   4. 返回映射 / 测试结果 / 评估 / 通过与否；映射失败或入参缺失是明确的 4xx。
RSpec.describe '单场景运行接口', type: :request do
  let(:code) { "module QingxunScript\n  class RunDemo < Qingxun::DeviceScript\n  end\nend" }
  let(:mapping) { [{ command: 'show version', response: 'Version 1.0' }] }
  let(:test_result) { { success: true, result: { 'ok' => true }, logs: ['log line'] } }
  let(:evaluation) do
    {
      passed: true, evaluation: '通过', suggestions: [], issues: [], items: [],
      env_mismatches: [], user_questions: [], mapping_suggestions: []
    }
  end

  def sign_in_user
    # 开源版免登录：所有请求都以本地操作员身份运行。
    User.local_operator
  end

  def post_run(body)
    post '/scripts/run_scenario', params: body, as: :json
  end


  describe '分支运行' do
    let(:captured) { {} }

    before do
      sign_in_user
      allow(BranchMappingGenerationService).to receive(:new) do |c, desc, mainline_description: nil, feedback: nil, user: nil, scenario_kind: :branch|
        captured[:mapping_code] = c
        captured[:mapping_desc] = desc
        captured[:mainline_description] = mainline_description
        captured[:scenario_kind] = scenario_kind
        instance_double(BranchMappingGenerationService, call: { command_mapping: mapping, error: nil })
      end
      allow(DebugSession).to receive(:new) do |c, _desc, m, _port, user: nil|
        captured[:debug_code] = c
        captured[:debug_mapping] = m
        instance_double(DebugSession, run: test_result)
      end
      allow(ScriptEvaluationService).to receive(:new) do |_desc, _code, _mapping, _tr|
        instance_double(ScriptEvaluationService, call: evaluation)
      end
    end

    it '返回映射/测试结果/评估，且脚本代码原样透传（不重新生成）' do
      post_run(code: code, kind: 'branch', name: '命令报错', description: '设备返回错误回显', mainline_description: '巡检交换机')

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['success']).to be true
      expect(body['kind']).to eq('branch')
      expect(body['command_mapping']).to eq([{ 'command' => 'show version', 'response' => 'Version 1.0' }])
      expect(body['test_result']['success']).to be true
      expect(body['passed']).to be true

      expect(captured[:scenario_kind]).to eq(:branch)
      expect(captured[:mapping_desc]).to eq('设备返回错误回显')
      expect(captured[:mainline_description]).to eq('巡检交换机')
      # 关键：两处拿到的都是原样的 code
      expect(captured[:mapping_code]).to eq(code)
      expect(captured[:debug_code]).to eq(code)
      expect(captured[:debug_mapping]).to eq(mapping)
    end

    it '评估未通过时 passed 为 false' do
      allow(ScriptEvaluationService).to receive(:new)
        .and_return(instance_double(ScriptEvaluationService, call: evaluation.merge(passed: false, issues: ['没有按预期记录'])))

      post_run(code: code, description: '场景')

      body = JSON.parse(response.body)
      expect(body['passed']).to be false
      expect(body['evaluation']['issues']).to eq(['没有按预期记录'])
    end
  end

  describe '主线运行' do
    it 'kind=main 时走 mainline 映射分支，不带主线背景参数' do
      sign_in_user
      captured = {}
      allow(BranchMappingGenerationService).to receive(:new) do |_c, _desc, mainline_description: nil, feedback: nil, user: nil, scenario_kind: :branch|
        captured[:scenario_kind] = scenario_kind
        captured[:mainline_description] = mainline_description
        instance_double(BranchMappingGenerationService, call: { command_mapping: mapping, error: nil })
      end
      allow(DebugSession).to receive(:new).and_return(instance_double(DebugSession, run: test_result))
      allow(ScriptEvaluationService).to receive(:new).and_return(instance_double(ScriptEvaluationService, call: evaluation))

      post_run(code: code, kind: 'main', description: '主线需求描述')

      expect(response).to have_http_status(:ok)
      expect(captured[:scenario_kind]).to eq(:main)
      expect(captured[:mainline_description]).to be_nil
    end
  end

  describe '入参校验' do
    before { sign_in_user }

    it '代码为空时 422，不调用任何服务' do
      expect(BranchMappingGenerationService).not_to receive(:new)

      post_run(code: '   ', description: '场景')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('请先生成脚本代码')
    end

    it '描述为空时 422' do
      post_run(code: code, description: '  ')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('场景描述不能为空')
    end
  end

  describe '映射生成失败' do
    it '返回 422 且提示映射生成失败，不进入运行' do
      sign_in_user
      allow(BranchMappingGenerationService).to receive(:new)
        .and_return(instance_double(BranchMappingGenerationService, call: { command_mapping: [], error: '模型抽风' }))
      expect(DebugSession).not_to receive(:new)

      post_run(code: code, description: '场景')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('命令映射生成失败')
    end
  end

  # 回归（线上实测的失败）：DebugSession 返回的 result 是 Qingxun::ScriptResult 对象，
  # `render json:` 会以 as_json(options) 调用它；该类原先 as_json 无参，
  # 导致运行接口一律 422 "wrong number of arguments (given 1, expected 0)"。
  describe '渲染真实 ScriptResult 对象' do
    it '返回 200，且 result 被序列化成 Hash' do
      sign_in_user
      script_result = Qingxun::ScriptResult.new(
        success: true, status: 'all_passed',
        summary: { passed: 1, failed: 0, total: 1 }, checkpoints: []
      )
      allow(BranchMappingGenerationService).to receive(:new)
        .and_return(instance_double(BranchMappingGenerationService, call: { command_mapping: mapping, error: nil }))
      allow(DebugSession).to receive(:new)
        .and_return(instance_double(DebugSession, run: { success: true, result: script_result, logs: ['x'] }))
      allow(ScriptEvaluationService).to receive(:new)
        .and_return(instance_double(ScriptEvaluationService, call: evaluation))

      post_run(code: code, description: '场景')

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['test_result']['result']).to be_a(Hash)
      expect(body['test_result']['result']['status']).to eq('all_passed')
    end
  end
end

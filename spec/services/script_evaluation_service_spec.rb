# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/script_evaluation_service'

RSpec.describe ScriptEvaluationService do
  let(:description) { '检查交换机版本' }
  let(:code) { 'class TestScript < Qingxun::DeviceScript; def run(c); end; end' }
  let(:command_mapping) { [{ command: 'show version', response: 'Version 1.0' }] }
  let(:test_result) { { success: true, result: { version: '1.0' }, logs: ['日志1'] } }
  let(:service) { described_class.new(description, code, command_mapping, test_result) }

  before do
    # 模拟 Rails 常量及其链式调用
    rails_app = double('Application', credentials: double('Credentials', deepseek_api_key: nil))
    rails_logger = double('Logger', error: nil, warn: nil)
    stub_const('Rails', double('Rails', logger: rails_logger, application: rails_app))
    # 模拟 ENV.fetch 返回一个 dummy key（默认）
    allow(ENV).to receive(:fetch).and_return('dummy_key')
  end

  describe '#call' do
    context '当 API 返回有效的评估结果时' do
      let(:api_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => <<~JSON
                  ```json
                  {
                    "passed": true,
                    "evaluation": "脚本功能完全覆盖用户需求，执行正确",
                    "suggestions": ["可以增加更多错误处理"],
                    "issues": []
                  }
                  ```
                JSON
              }
            }
          ]
        }
      end

      before do
        allow(LlmRequestService).to receive(:call).and_return(api_response)
      end

      it '返回解析后的评估结果' do
        result = service.call

        expect(result[:passed]).to be true
        expect(result[:evaluation]).to eq('脚本功能完全覆盖用户需求，执行正确')
        expect(result[:suggestions]).to eq(['可以增加更多错误处理'])
        expect(result[:issues]).to eq([])
      end
    end

    context '当 API 返回评估未通过时' do
      let(:api_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => <<~JSON
                  ```json
                  {
                    "passed": false,
                    "evaluation": "脚本未能正确提取版本信息",
                    "suggestions": ["请检查正则表达式"],
                    "issues": ["输出解析错误"]
                  }
                  ```
                JSON
              }
            }
          ]
        }
      end

      before do
        allow(LlmRequestService).to receive(:call).and_return(api_response)
      end

      it '返回解析后的评估结果，passed 为 false' do
        result = service.call

        expect(result[:passed]).to be false
        expect(result[:evaluation]).to eq('脚本未能正确提取版本信息')
        expect(result[:suggestions]).to eq(['请检查正则表达式'])
        expect(result[:issues]).to eq(['输出解析错误'])
      end
    end

    context '当 API 返回的 JSON 没有代码块时' do
      let(:api_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => '{"passed": true, "evaluation": "直接 JSON", "suggestions": [], "issues": []}'
              }
            }
          ]
        }
      end

      before do
        allow(LlmRequestService).to receive(:call).and_return(api_response)
      end

      it '仍然能解析 JSON' do
        result = service.call

        expect(result[:passed]).to be true
        expect(result[:evaluation]).to eq('直接 JSON')
      end
    end

    context '当 API 返回的 JSON 解析失败时' do
      let(:api_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => '无效的 JSON 内容'
              }
            }
          ]
        }
      end

      before do
        allow(LlmRequestService).to receive(:call).and_return(api_response)
      end

      it '尝试从文本推断 passed 状态' do
        result = service.call

        expect(result[:passed]).to be false  # 因为内容不包含 "passed": true
        expect(result[:issues]).to include('无法解析结构化评估结果')
      end
    end

    context '当 API 请求失败时' do
      before do
        allow(LlmRequestService).to receive(:call).and_raise(RuntimeError.new('API 错误'))
      end

      it '返回错误评估结果' do
        result = service.call

        expect(result[:passed]).to be false
        expect(result[:evaluation]).to include('评估过程发生错误')
        expect(result[:issues]).to include('评估服务异常')
      end
    end

    context '当 API 密钥未配置时' do
      before do
        allow(LlmRequestService).to receive(:call).and_raise(RuntimeError.new('API 密钥未配置'))
      end

      it '引发异常并被 rescue，返回错误结果' do
        result = service.call

        expect(result[:passed]).to be false
        expect(result[:evaluation]).to include('评估过程发生错误')
      end
    end

    describe 'sanitize_test_result' do
      it '限制日志长度' do
        long_logs = (1..60).map { |i| "日志 #{i}" }
        test_result = { logs: long_logs }
        service = described_class.new(description, code, command_mapping, test_result)
        # 通过私有方法测试需要发送 :sanitize_test_result
        sanitized = service.send(:sanitize_test_result)
        expect(sanitized[:logs].length).to eq(41)  # 40条 + 截断提示
        expect(sanitized[:logs].last).to include('已截断')
      end

      it '包含必要的字段' do
        test_result = { success: false, error: '错误', result: { a: 1 }, logs: ['log'], backtrace: ['line1'] }
        service = described_class.new(description, code, command_mapping, test_result)
        sanitized = service.send(:sanitize_test_result)
        expect(sanitized[:success]).to be false
        expect(sanitized[:error]).to eq('错误')
        expect(sanitized[:result]).to eq({ a: 1 })
        expect(sanitized[:logs]).to eq(['log'])
        expect(sanitized[:backtrace]).to eq(['line1'])
      end

      # 设备报文常常整段塞进一条日志，单行也得截，否则 prompt 依然会被灌满
      it '单行超长时截断该行' do
        long_line = 'x' * 5000
        service = described_class.new(description, code, command_mapping, { logs: [long_line] })
        sanitized = service.send(:sanitize_test_result)

        expect(sanitized[:logs].first.length).to be < 5000
        expect(sanitized[:logs].first).to include('本行已截断')
      end
    end

    describe '逐条评估结果' do
      let(:api_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => <<~JSON
                  ```json
                  {
                    "items": [
                      {"requirement": "下发 show version", "checkpoint": "检查版本", "passed": true,
                       "expected": "拿到版本号", "observed": "Version 1.0",
                       "evidence": "Version 1.0", "attribution": "ok", "note": ""},
                      {"requirement": "数值低于最大水线的 90%", "checkpoint": null, "passed": false,
                       "expected": "< 90%", "observed": "命中阈值", "evidence": "UseRate(%) 99%",
                       "attribution": "script_issue", "note": "未做阈值判断"}
                    ],
                    "passed": false,
                    "evaluation": "一条未通过",
                    "suggestions": ["补充阈值判断"],
                    "issues": ["缺少阈值判断"],
                    "env_mismatches": ["diag shell PFU-0/0/0 无映射，回放 not recognized"],
                    "mapping_suggestions": [
                      {"command": "diag shell PFU-0/0/0", "issue": "映射缺失",
                       "suggested_response": "", "reason": "需求写明该命令收到空字符串"}
                    ]
                  }
                  ```
                JSON
              }
            }
          ]
        }
      end

      before { allow(LlmRequestService).to receive(:call).and_return(api_response) }

      it '解析出逐条结果，保留证据与归因' do
        result = service.call

        expect(result[:passed]).to be false
        expect(result[:items].size).to eq(2)
        expect(result[:items][0][:passed]).to be true
        expect(result[:items][0][:evidence]).to eq('Version 1.0')
        expect(result[:items][1][:passed]).to be false
        expect(result[:items][1][:attribution]).to eq('script_issue')
      end

      it '解析出命令映射补充建议（含建议报文），供下一轮补齐映射' do
        result = service.call

        expect(result[:mapping_suggestions].size).to eq(1)
        suggestion = result[:mapping_suggestions].first
        expect(suggestion[:command]).to eq('diag shell PFU-0/0/0')
        expect(suggestion[:suggested_response]).to eq('')
        expect(suggestion[:reason]).to include('空字符串')
      end
    end

    describe 'passed 与条目一致性' do
      let(:api_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => <<~JSON
                  ```json
                  {
                    "items": [
                      {"requirement": "条目A", "passed": true, "evidence": "ok", "attribution": "ok"},
                      {"requirement": "条目B", "passed": false, "evidence": "mock 回 not recognized",
                       "attribution": "env_mismatch"}
                    ],
                    "passed": true,
                    "evaluation": "模型说通过，但有条目失败",
                    "suggestions": [],
                    "issues": [],
                    "env_mismatches": ["diagnose 映射为空但回 not recognized"]
                  }
                  ```
                JSON
              }
            }
          ]
        }
      end

      before { allow(LlmRequestService).to receive(:call).and_return(api_response) }

      # 防止"个别检查点失败、整体却通过"的自相矛盾结论
      it '有条目未通过时强制 passed=false' do
        result = service.call

        expect(result[:passed]).to be false
        expect(result[:env_mismatches]).to include('diagnose 映射为空但回 not recognized')
      end
    end

    describe '非本次需求范围的问题不影响 passed' do
      let(:api_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => <<~JSON
                  ```json
                  {
                    "items": [
                      {"requirement": "下发 display version", "passed": true, "evidence": "VRP 5.170",
                       "attribution": "ok", "note": ""}
                    ],
                    "passed": false,
                    "evaluation": "本次需求条目全部通过，但脚本其他部分存在硬编码",
                    "suggestions": ["后续迭代清理硬编码"],
                    "issues": ["脚本别处硬编码 diagnose 密码 'jjj'（非本次需求范围）"],
                    "env_mismatches": [],
                    "user_questions": [],
                    "mapping_suggestions": []
                  }
                  ```
                JSON
              }
            }
          ]
        }
      end

      before { allow(LlmRequestService).to receive(:call).and_return(api_response) }

      # 实测问题：分支描述的需求条目全部通过，但模型在正文里提到共享脚本其他环节的问题，
      # 并把顶层 passed 写成 false，页面于是显示"测试未通过"，与评估正文自相矛盾。
      it '条目全部通过时以条目为准判通过，无关问题保留在 issues 中' do
        result = service.call

        expect(result[:passed]).to be true
        expect(result[:items].size).to eq(1)
        expect(result[:issues].first).to include('非本次需求范围')
      end
    end

    describe '需要用户确认的信息' do
      let(:api_response) do
        {
          'choices' => [
            {
              'message' => {
                'content' => <<~JSON
                  ```json
                  {
                    "items": [
                      {"requirement": "记录网元名称", "passed": false, "expected": "真实网元名",
                       "observed": "日志写成 网络名称: 默认网络", "evidence": "日志: 网络名称: 默认网络",
                       "attribution": "needs_user_confirmation", "note": "脚本无数据来源"}
                    ],
                    "passed": false,
                    "evaluation": "有一条依赖用户提供的信息",
                    "issues": ["网元名称无来源，脚本疑似编造"],
                    "suggestions": [],
                    "env_mismatches": [],
                    "user_questions": ["网元名称从哪里获取？"],
                    "mapping_suggestions": []
                  }
                  ```
                JSON
              }
            }
          ]
        }
      end

      before { allow(LlmRequestService).to receive(:call).and_return(api_response) }

      it '保留 needs_user_confirmation 归因，并解析 user_questions' do
        result = service.call

        expect(result[:items].first[:attribution]).to eq('needs_user_confirmation')
        expect(result[:user_questions]).to eq(['网元名称从哪里获取？'])
        expect(result[:passed]).to be false
      end
    end

    describe '生成提示词约束' do
      let(:prompt) { Prompts::ScriptGeneration.build('', '需求：记录网元名称') }

      it '声明可用上下文并禁止编造无来源字段' do
        expect(prompt).to include('device_config')
        expect(prompt).to include('严禁编造字段值')
        expect(prompt).to include('[待确认]')
        expect(prompt).to include('拿不准就回抛用户')
      end

      it '要求命令集中在主函数、解析/检查独立成函数并带输入输出样例' do
        expect(prompt).to include('所有 connection.cli')
        expect(prompt).to include('解析函数')
        expect(prompt).to include('检查函数')
        expect(prompt).to include('输入样例')
        expect(prompt).to include('输出样例')
        expect(Prompts::ScriptGeneration.system_prompt).to include('主函数 run')
      end

      it '禁止把原始回显再抄进日志（框架已自动记录）' do
        expect(prompt).to include('不要记录原始回显')
        expect(prompt).to include('自动记录')
        expect(prompt).to include('解析出的关键值')
        expect(Prompts::ScriptGeneration.system_prompt).to include('不要用 log_info 记录原始回显')
      end

      # 生成侧要求写"[步骤N] 开始/结束"，评估侧就不能把它们当冗余日志扣分（否则两边口径打架）
      it '步骤边界日志不算冗余（评估提示词里的豁免）' do
        evaluation_prompt = Prompts::ScriptEvaluation.build('需求', '代码', [], {})

        expect(evaluation_prompt).to include('步骤边界日志')
        expect(evaluation_prompt).to include('不得')
        expect(evaluation_prompt).to include('判为冗余日志或噪音')
      end
    end

    describe '评估提示词' do
      let(:prompt) do
        Prompts::ScriptEvaluation.build(
          '需求：下发 diagnose，收到空字符串或 Password 提示',
          'class X; end',
          [{ command: 'diagnose', response: '' }],
          { success: true, result: { checkpoints: [{ name: '进入诊断模式', passed: false }] }, logs: ['log'] }
        )
      end

      it '要求逐条评估、证据绑定与环境归因' do
        expect(prompt).to include('逐条')
        expect(prompt).to include('"items"')
        expect(prompt).to include('evidence')
        expect(prompt).to include('env_mismatch')
        expect(prompt).to include('仅当所有需求条目都 passed=true')
      end

      it '声明非本次需求范围的问题不影响 passed' do
        expect(prompt).to include('非本次需求范围')
        expect(prompt).to include('不得')
      end

      # 代码一旦被转义成 `\#{`，评估就照着自己看到的文本判"双引号内不会插值"并提假问题
      # （实测 9/13–9/25 累计 21 条，而生成侧回复里字面量 \#{ 出现 0 次），所以必须原样展示
      it '脚本代码原样进提示词，不做插值转义' do
        prompt_with_interpolation = Prompts::ScriptEvaluation.build(
          '需求', 'log_info("#{list}")', [], {}
        )

        expect(prompt_with_interpolation).to include('log_info("#{list}")')
        expect(prompt_with_interpolation).not_to include('\#{list}')
      end

      it '约束 user_questions 只服务于 needs_user_confirmation，已给信息与范围外步骤不再追问' do
        expect(prompt).to include('必须是空数组')
        expect(prompt).to include('已给出')
        expect(prompt).to include('本次需求描述')
      end

      it '要求识别编造值，并把无来源的信息回抛给用户' do
        expect(prompt).to include('needs_user_confirmation')
        expect(prompt).to include('user_questions')
        expect(prompt).to include('编造')
        expect(prompt).to include('默认网络')
      end

      it '把脚本记录的检查点带进提示词，便于条目对齐' do
        expect(prompt).to include('进入诊断模式')
      end

      it '超长的映射响应会被截断，避免 prompt 膨胀' do
        long_response = 'A' * 1500
        built = Prompts::ScriptEvaluation.build('d', 'c', [{ command: 'x', response: long_response }], {})

        expect(built).to include('已截断')
        expect(built).not_to include('A' * 1200)
      end
    end
  end
end
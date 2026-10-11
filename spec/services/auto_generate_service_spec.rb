# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/auto_generate_service'

RSpec.describe AutoGenerateService do
  let(:description) { '检查交换机版本' }
  let(:service) { described_class.new(description) }

  # 模拟依赖的服务
  let(:mock_generation_service) { instance_double(ScriptGenerationService) }
  let(:mock_debug_session) { instance_double(DebugSession) }
  let(:mock_evaluation_service) { instance_double(ScriptEvaluationService) }

  before do
    # 模拟 Rails 常量及其链式调用
    rails_app = double('Application', credentials: double('Credentials', deepseek_api_key: nil))
    rails_logger = double('Logger', info: nil, warn: nil, error: nil)
    stub_const('Rails', double('Rails', logger: rails_logger, application: rails_app))
    # 模拟 ENV.fetch 返回 nil（默认）
    allow(ENV).to receive(:fetch).and_return(nil)
    # 模拟 LlmRequestService
    allow(LlmRequestService).to receive(:call).and_return(
      { 'choices' => [{ 'message' => { 'content' => '默认建议' } }] }
    )
    # 模拟依赖的服务类
    allow(ScriptGenerationService).to receive(:new).and_return(mock_generation_service)
    allow(DebugSession).to receive(:new).and_return(mock_debug_session)
    allow(ScriptEvaluationService).to receive(:new).and_return(mock_evaluation_service)
  end

  describe '#call' do
    context '当脚本生成、测试和评估都一次性成功时' do
      before do
        allow(mock_generation_service).to receive(:call).and_return({
          code: 'class TestScript < Qingxun::DeviceScript; end',
          command_mapping: [{ command: 'show version', response: 'Version 1.0' }],
          description: '测试脚本',
          enhanced_description: '增强后的描述'
        })
        allow(mock_debug_session).to receive(:run).and_return({
          success: true,
          logs: ['日志1'],
          result: { command: 'show version', version: '1.0' }
        })
        allow(mock_evaluation_service).to receive(:call).and_return({
          passed: true,
          evaluation: '评估通过',
          issues: [],
          suggestions: []
        })
      end

      it '返回成功结果，且尝试次数为1' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:attempts]).to eq(1)
        expect(result[:code]).to include('class TestScript')
        expect(result[:command_mapping]).to eq([{ command: 'show version', response: 'Version 1.0' }])
        expect(result[:evaluation][:passed]).to be true
      end

      it '调用进度回调' do
        progress_events = []
        result = service.call do |progress|
          progress_events << progress
        end

        expect(progress_events).not_to be_empty
        # 至少应该有 start_attempt, generating, generated, testing, tested, evaluating, evaluated, success
        expect(progress_events.map { |e| e[:stage] }).to include(:start_attempt, :generating, :generated, :testing, :tested, :evaluating, :evaluated, :success)
      end
    end

    context '当评估未通过，但重试后成功时' do
      before do
        # 第一次尝试：评估失败
        allow(mock_generation_service).to receive(:call).and_return(
          {
            code: 'class Attempt1 < Qingxun::DeviceScript; end',
            command_mapping: [{ command: 'show version', response: 'Version 1.0' }],
            description: '第一次尝试',
            enhanced_description: '增强后的描述'
          },
          {
            code: 'class Attempt2 < Qingxun::DeviceScript; end',
            command_mapping: [{ command: 'show version', response: 'Version 2.0' }],
            description: '第二次尝试',
            enhanced_description: '增强后的描述'
          }
        )
        allow(mock_debug_session).to receive(:run).and_return(
          { success: true, logs: ['日志1'], result: { command: 'show version', version: '1.0' } },
          { success: true, logs: ['日志2'], result: { command: 'show version', version: '2.0' } }
        )
        allow(mock_evaluation_service).to receive(:call).and_return(
          { passed: false, evaluation: '评估未通过', issues: ['问题1'], suggestions: ['建议1'] },
          { passed: true, evaluation: '评估通过', issues: [], suggestions: [] }
        )
      end

      it '重试一次后成功，返回第二次尝试的结果' do
        result = service.call

        expect(result[:success]).to be true
        expect(result[:attempts]).to eq(2)
        expect(result[:code]).to include('class Attempt2')
        expect(result[:evaluation][:passed]).to be true
      end

      it '进度回调包含 retry 事件' do
        progress_events = []
        service.call do |progress|
          progress_events << progress
        end

        retry_events = progress_events.select { |e| e[:stage] == :retry }
        expect(retry_events).not_to be_empty
        expect(retry_events.first[:attempt]).to eq(1)
      end
    end

    context '当三次尝试均失败时' do
      before do
        allow(mock_generation_service).to receive(:call).and_return(
          {
            code: 'class Attempt1 < Qingxun::DeviceScript; end',
            command_mapping: [],
            description: '第一次尝试',
            enhanced_description: '增强后的描述'
          }
        ).exactly(3).times
        allow(mock_debug_session).to receive(:run).and_return(
          { success: true, logs: [], result: {} }
        ).exactly(3).times
        allow(mock_evaluation_service).to receive(:call).and_return(
          { passed: false, evaluation: '评估未通过', issues: ['问题'], suggestions: ['建议'] }
        ).exactly(3).times
        # 模拟最终建议 API 调用
        allow(LlmRequestService).to receive(:call).and_return(
          { 'choices' => [{ 'message' => { 'content' => '最终建议内容' } }] }
        )
      end

      it '返回失败结果，包含最终建议' do
        result = service.call

        expect(result[:success]).to be false
        expect(result[:attempts]).to eq(3)
        expect(result[:final_suggestion]).to eq('最终建议内容')
      end

      it '进度回调包含 final_failed 事件' do
        progress_events = []
        service.call do |progress|
          progress_events << progress
        end

        final_failed_events = progress_events.select { |e| e[:stage] == :final_failed }
        expect(final_failed_events).not_to be_empty
      end
    end

    context '当脚本生成失败时' do
      before do
        allow(mock_generation_service).to receive(:call).and_raise(RuntimeError.new('生成失败'))
        # 确保测试和评估不被调用
        expect(mock_debug_session).not_to receive(:run)
        expect(mock_evaluation_service).not_to receive(:call)
      end

      it '跳过测试和评估，直接重试' do
        progress_events = []
        service.call do |progress|
          progress_events << progress
        end

        generation_failed_events = progress_events.select { |e| e[:stage] == :generation_failed }
        expect(generation_failed_events).not_to be_empty
        # 应该尝试了3次（因为生成失败会继续重试）
        expect(generation_failed_events.count).to eq(3)
      end
    end

    context '当测试执行失败时' do
      before do
        allow(mock_generation_service).to receive(:call).and_return(
          {
            code: 'class TestScript < Qingxun::DeviceScript; end',
            command_mapping: [],
            description: '测试脚本',
            enhanced_description: '增强后的描述'
          }
        )
        allow(mock_debug_session).to receive(:run).and_return(
          { success: false, error: '测试错误', logs: [] }
        )
        allow(mock_evaluation_service).to receive(:call).and_return(
          { passed: false, evaluation: '测试失败', issues: ['测试错误'], suggestions: [] }
        )
      end

      it '评估会失败，并重试' do
        progress_events = []
        service.call do |progress|
          progress_events << progress
        end

        tested_events = progress_events.select { |e| e[:stage] == :tested }
        expect(tested_events).not_to be_empty
        expect(tested_events.first.dig(:result, :error)).to eq('测试错误')
      end
    end
  end
end
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BranchConsistencyService do
  let(:mainline) { "下发命令：show version\n处理：拿不到型号则提示\"模板与设备类型不符\"并结束" }
  let(:branches) do
    [
      { name: '型号不符', description: "命令 show version\n报文\nZXCTN 6500-2\n处理：提示模板与设备类型不符并结束" },
      { name: 'Base报错', description: "命令 show install active | include Base\n报文\n%Error\n处理：判命令执行失败并结束" }
    ]
  end

  def llm_returning(content)
    allow(LlmRequestService).to receive(:call).and_return(
      'choices' => [{ 'message' => { 'content' => content } }]
    )
  end

  describe '#call' do
    it '解析每条分支的判定，并与输入一一对齐' do
      llm_returning(<<~CONTENT)
        ```json
        { "results": [
          { "index": 0, "name": "型号不符", "verdict": "ok", "reason": "只是换了报文触发主线已声明的规则", "offending": [] },
          { "index": 1, "name": "Base报错", "verdict": "stricter", "reason": "主线未在 Base 命令上声明 %Error 处理", "offending": ["新增了主线未声明的失败处理"] }
        ] }
        ```
      CONTENT

      result = described_class.new(mainline, branches).call

      expect(result[:success]).to be true
      expect(result[:results].size).to eq(2)
      expect(result[:results][0][:verdict]).to eq('ok')
      expect(result[:results][1][:verdict]).to eq('stricter')
      expect(result[:results][1][:name]).to eq('Base报错')
      expect(result[:results][1][:offending]).to eq(['新增了主线未声明的失败处理'])
      expect(result[:has_issues]).to be true
    end

    it '模型漏项时补 unknown，保证与输入对齐' do
      llm_returning('{ "results": [ { "index": 0, "verdict": "ok", "reason": "ok" } ] }')

      result = described_class.new(mainline, branches).call

      expect(result[:results].size).to eq(2)
      expect(result[:results][1][:verdict]).to eq('unknown')
      expect(result[:results][1][:name]).to eq('Base报错')
      expect(result[:has_issues]).to be true
    end

    it '无法识别的 verdict 记为 unknown（不误判为合规）' do
      llm_returning('{ "results": [ { "index": 0, "verdict": "OK!" } ] }')

      result = described_class.new(mainline, branches).call

      expect(result[:results][0][:verdict]).to eq('unknown')
    end

    it 'LLM 调用失败时降级为 success:false，不抛异常' do
      allow(LlmRequestService).to receive(:call).and_raise(StandardError, 'boom')

      result = described_class.new(mainline, branches).call

      expect(result[:success]).to be false
      expect(result[:results]).to eq([])
      expect(result[:error]).to include('boom')
    end

    it '主线描述为空时直接返回错误，不调用 LLM' do
      expect(LlmRequestService).not_to receive(:call)

      result = described_class.new('   ', branches).call

      expect(result[:success]).to be false
      expect(result[:error]).to include('主线描述不能为空')
    end

    it '没有分支时直接通过，不调用 LLM' do
      expect(LlmRequestService).not_to receive(:call)

      result = described_class.new(mainline, []).call

      expect(result[:success]).to be true
      expect(result[:results]).to eq([])
      expect(result[:has_issues]).to be false
    end
  end

  describe '提示词口径' do
    it '声明三种判定，并要求"主线未声明不得引入、规则不得挪用"' do
      prompt = Prompts::BranchConsistency.build(mainline, branches)

      expect(prompt).to include('stricter')
      expect(prompt).to include('contradiction')
      expect(prompt).to include('规则应跟着它所在的命令走')
      expect(prompt).to include('未声明')
      expect(Prompts::BranchConsistency.system_prompt).to include('主线未声明')
      expect(Prompts::BranchConsistency.system_prompt).to include('stricter')
    end
  end
end

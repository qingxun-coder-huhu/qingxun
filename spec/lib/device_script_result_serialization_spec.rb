# frozen_string_literal: true

require 'spec_helper'
require 'json'
require_relative '../../lib/qingxun/device_script'

# 脚本结果必须能被 JSON 正确序列化
#
# 背景（实测踩过的真问题）：ScriptResult/Checkpoint 只定义了 as_json/to_h，
# 而标准库 JSON.generate / JSON.pretty_generate **不调用 as_json**，
# 于是评估 prompt 里的测试结果变成 "#<Qingxun::ScriptResult:0x...>" 字符串，
# summary 与 checkpoints 全部丢失——评估因此看不到任何检查点，
# 只能靠日志猜，还把"检查点为空"误判成环境问题。
RSpec.describe 'Qingxun 脚本结果的 JSON 序列化' do
  let(:checkpoint) do
    Qingxun::Checkpoint.new(
      name: '进入诊断模式', passed: false, command: 'diagnose',
      expected: '进入诊断模式', reason: 'mock 回 not recognized'
    )
  end

  let(:result) do
    Qingxun::ScriptResult.new(
      success: true, status: 'some_failed',
      summary: { passed: 0, failed: 1, total: 1 },
      checkpoints: [checkpoint]
    )
  end

  it 'checkpoints 与 summary 能经 JSON.generate 完整保留' do
    parsed = JSON.parse(JSON.generate({ result: result }))

    expect(parsed.dig('result', 'summary', 'failed')).to eq(1)
    expect(parsed.dig('result', 'checkpoints').size).to eq(1)
    expect(parsed.dig('result', 'checkpoints', 0, 'name')).to eq('进入诊断模式')
    expect(parsed.dig('result', 'checkpoints', 0, 'command')).to eq('diagnose')
  end

  it 'JSON.pretty_generate 同样不再输出对象地址字符串' do
    text = JSON.pretty_generate({ result: result })

    expect(text).not_to include('#<Qingxun::ScriptResult')
    expect(text).to include('进入诊断模式')
  end

  # 背景（线上实测的 500/422）：Rails 的 `render json:` 内部走
  # `to_json(options)` → ActiveSupport 会以 **`as_json(options)`** 调用对象。
  # 原先 `def as_json` 无参，一进控制器 render 就抛
  # "wrong number of arguments (given 1, expected 0)"——单场景「运行」接口就这样挂过。
  it 'as_json 接受可选的 options 参数（ActiveSupport 会带参调用）' do
    expect { result.as_json({}) }.not_to raise_error
    expect(result.as_json({})).to eq(result.to_h)
    expect { checkpoint.as_json({}) }.not_to raise_error
    expect(checkpoint.as_json({})).to eq(checkpoint.to_h)
  end
end

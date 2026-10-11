# frozen_string_literal: true

require 'rails_helper'

# LLM 交互的文件日志：JSON（给程序）+ 可读 .log（给人看提示词）
#
# 背景：JSON 里的换行是转义的 \n，提示词一整行很难读。因此在每个交互旁再写一份
# 带真实换行的 .log，便于直接观察提示词与模型响应。
RSpec.describe LlmSessionLogger, '可读日志' do
  let(:context) { { request_id: 'readable-spec', user_id: nil, request_type: 'web', path: '/x' } }

  def write_interaction(success: true)
    handle = described_class.start(
      context,
      service_name: 'DemoService',
      step_name: 'build_prompt',
      model: 'deepseek-chat',
      messages: [
        { role: 'system', content: "第一行系统提示\n第二行系统提示" },
        { role: 'user', content: "需求：\n下发命令：show version" }
      ]
    )
    if success
      handle.success({ 'choices' => [{ 'message' => { 'content' => "响应第一行\n响应第二行" } }] }, 12.3)
    else
      handle.failure('上游返回 401', 5.0)
    end
  end

  def session_dir
    described_class.session_dir_for(context[:request_id])
  end

  after { FileUtils.rm_rf(described_class.session_dir_for('readable-spec')) }

  it '在 JSON 旁生成同名 .log，且内容带真实换行' do
    write_interaction
    logs = Dir.glob(File.join(session_dir.to_s, '*.log'))
    expect(logs.size).to eq(1)

    text = File.read(logs.first)
    # 关键：换行是真实的，不是转义的 \n
    expect(text).to include("第一行系统提示\n第二行系统提示")
    expect(text).to include("响应第一行\n响应第二行")
    expect(text).not_to include('\\n')
    # 角色分区便于快速定位提示词
    expect(text).to include('SYSTEM')
    expect(text).to include('USER')
    expect(text).to include('响应')
  end

  it 'JSON 与 .log 同时存在，读取逻辑只认 JSON' do
    write_interaction
    json_files = Dir.glob(File.join(session_dir.to_s, '*.json')).reject { |f| File.basename(f) == '_session.json' }
    log_files = Dir.glob(File.join(session_dir.to_s, '*.log'))

    expect(json_files.size).to eq(1)
    expect(log_files.size).to eq(1)
    # read 只返回结构化交互，不会把 .log 当成一条记录
    expect(described_class.read(context[:request_id]).size).to eq(1)
  end

  it '失败交互也写 .log，并带上错误信息' do
    write_interaction(success: false)
    text = File.read(Dir.glob(File.join(session_dir.to_s, '*.log')).first)

    expect(text).to include('成功: false')
    expect(text).to include('上游返回 401')
  end
end

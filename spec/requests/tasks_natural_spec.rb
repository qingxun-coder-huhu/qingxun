# frozen_string_literal: true

require 'rails_helper'

# 自然语言生成任务（POST /tasks/natural）——对齐客户端：AI 匹配设备/脚本后建任务。
# 服务本身需要真实 LLM，这里一律桩掉，只验证：落地映射、命名、权限过滤与错误回传。
RSpec.describe '自然语言生成任务', type: :request do
  let(:user) { User.local_operator }

  let(:device) do
    user.network_elements.create!(name: "d-#{SecureRandom.hex(3)}", ip_address: '10.0.0.9',
                                  port: 22, connection_type: 'ssh', username: 'a', password: 'x',
                                  device_model: 'linux', description: '核心主机')
  end

  let(:script) do
    user.scripts.create!(script_uid: Script.generate_unique_uid, name: "s-#{SecureRandom.hex(3)}",
                         description: 'x', version: '1.0.0', device_models: ['linux'],
                         publish_status: :debugged,
                         code: "class X < Qingxun::DeviceScript\n  def run(c); end\nend")
  end

  # 服务返回的按型号分组定义（LLM 会把我们传进去的 id 原样带回来）
  def definition_for(dev, scr)
    { 'linux' => { 'devs' => [{ 'id' => dev.id, 'name' => dev.name, 'device_model' => 'linux' }],
                   'scripts' => [{ 'id' => scr.id, 'name' => scr.name, 'device_models' => ['linux'] }] } }
  end

  def stub_service(result)
    allow(TaskCreationFromNaturalLanguageService).to receive(:new).and_return(double(call: result))
  end

  it '成功：按型号分组定义落地成任务，并挂上匹配的设备与脚本' do
    d = device
    s = script
    stub_service(success: true, data: definition_for(d, s), self_check_count: 1)

    expect do
      post '/tasks/natural', params: { natural_language: '巡检所有 linux 主机' }, as: :json
    end.to change(Task, :count).by(1)

    body = JSON.parse(response.body)
    expect(response).to have_http_status(:ok)
    expect(body['success']).to be(true)

    task = Task.find(body['task_id'])
    expect(task.name).to start_with('AI生成任务: ')
    expect(task.description).to eq('巡检所有 linux 主机')
    expect(task.network_elements).to include(d)
    expect(task.scripts).to include(s)
    expect(task.device_count).to eq(1)
    expect(task.script_count).to eq(1)
    expect(body['path']).to eq("/tasks/#{task.id}")
  end

  it '服务失败：回传 error 与 code，不建任务' do
    stub_service(success: false, error: '还没有设备', code: 'no_devices')

    expect do
      post '/tasks/natural', params: { natural_language: '巡检' }, as: :json
    end.not_to change(Task, :count)

    body = JSON.parse(response.body)
    expect(body['success']).to be(false)
    expect(body['error']).to eq('还没有设备')
    expect(body['code']).to eq('no_devices')
  end

  it '空描述：400，不调用服务' do
    expect(TaskCreationFromNaturalLanguageService).not_to receive(:new)
    post '/tasks/natural', params: { natural_language: '  ' }, as: :json
    expect(response).to have_http_status(:bad_request)
  end

  it 'LLM 回传的脚本未处于「调试完成」：视为未匹配，不建任务' do
    d = device
    draft = user.scripts.create!(script_uid: Script.generate_unique_uid, name: "draft-#{SecureRandom.hex(3)}",
                                 description: 'x', version: '1.0.0', device_models: ['linux'],
                                 publish_status: :debugging,
                                 code: "class X < Qingxun::DeviceScript\n  def run(c); end\nend")
    stub_service(success: true, data: definition_for(d, draft), self_check_count: 1)

    expect do
      post '/tasks/natural', params: { natural_language: '巡检' }, as: :json
    end.not_to change(Task, :count)

    body = JSON.parse(response.body)
    expect(body['success']).to be(false)
    expect(body['code']).to eq('no_match')
  end
end

# frozen_string_literal: true

require 'rails_helper'

# 设备列表的「执行」操作：选定脚本 → 建设备任务 → 重定向到任务详情
RSpec.describe '设备执行', type: :request do
  let(:user) { User.local_operator }

  let(:device) do
    user.network_elements.create!(
      name: "d-#{SecureRandom.hex(3)}", ip_address: '127.0.0.1', port: 1,
      connection_type: 'telnet', username: 'admin', password: 'x'
    )
  end

  let(:script) do
    user.scripts.create!(
      script_uid: Script.generate_unique_uid, name: "s-#{SecureRandom.hex(3)}",
      description: 'x', version: '1.0.0', device_models: [], publish_status: :debugging,
      # 命令映射用数组形态（本项目脚本的实际形态），确保不会因它被当成 parameters 而校验失败
      command_mapping: [{ 'command' => 'show version', 'response' => 'ok' }],
      code: "class X < Qingxun::DeviceScript\n  def run(c); end\nend"
    )
  end

  before do
    # 不真的在后台连设备：只验证控制器的编排与重定向
    allow(TaskRunner).to receive(:start_async)
  end

  it '选定脚本后建任务并重定向到任务详情' do
    expect do
      post execute_network_element_path(device), params: { script_ids: [script.id] }
    end.to change(Task, :count).by(1)

    task = Task.order(:id).last
    expect(response).to redirect_to(task_path(task))
    expect(task.network_elements).to include(device)
    expect(task.scripts).to include(script)
    expect(task.device_count).to eq(1)
    expect(task.script_count).to eq(1)
    expect(TaskRunner).to have_received(:start_async)
  end

  it '未选脚本时不建任务并给出提示' do
    expect do
      post execute_network_element_path(device), params: {}
    end.not_to change(Task, :count)

    expect(response).to redirect_to(network_elements_path)
  end

  describe 'POST /network_elements/execute_batch（批量执行）' do
    it '多设备 + 多脚本建一个任务并返回跳转路径' do
      response_body = nil
      expect do
        post execute_batch_network_elements_path,
             params: { device_ids: [device.id], script_ids: [script.id] }, as: :json
        response_body = JSON.parse(response.body)
      end.to change(Task, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response_body['success']).to be true
      expect(response_body['path']).to eq(task_path(Task.order(:id).last))
      expect(Task.order(:id).last.network_elements).to include(device)
      expect(TaskRunner).to have_received(:start_async)
    end

    it '未选设备或脚本时返回 422' do
      post execute_batch_network_elements_path, params: { device_ids: [], script_ids: [] }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['success']).to be false
    end
  end
end

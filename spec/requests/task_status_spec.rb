# frozen_string_literal: true

require 'rails_helper'

# 任务状态接口（详情页轮询用）——结构对齐客户端：execution_units = 按设备分组的网元
RSpec.describe '任务状态接口', type: :request do
  let(:user) { User.local_operator }

  let(:device) do
    user.network_elements.create!(name: "d-#{SecureRandom.hex(3)}", ip_address: '10.0.0.1',
                                  port: 23, connection_type: 'telnet', username: 'a', password: 'x',
                                  description: '核心交换机')
  end

  let(:script) do
    user.scripts.create!(script_uid: Script.generate_unique_uid, name: "s-#{SecureRandom.hex(3)}",
                         description: 'x', version: '1.0.0', device_models: [], publish_status: :debugging,
                         code: "class X < Qingxun::DeviceScript\n  def run(c); end\nend")
  end

  let(:task) do
    t = user.tasks.create!(name: "t-#{SecureRandom.hex(3)}", description: 'd')
    t.scripts = [script]
    t.network_elements = [device]
    t.device_count = 1
    t.script_count = 1
    t.save!
    t
  end

  it '返回任务状态与按设备分组的网元/脚本/检查点结构' do
    task.update!(status: 'running')
    task.task_executions.create!(
      network_element_id: device.id, script_id: script.id, status: 'completed',
      logs: "line1\nline2", duration_ms: 1234,
      result: { 'status' => 'all_passed', 'checkpoints' => [{ 'name' => '检查项', 'passed' => true, 'value' => 'ok' }] }
    )

    get status_task_path(task), headers: { 'Accept' => 'application/json' }
    body = JSON.parse(response.body)

    expect(response).to have_http_status(:ok)
    expect(body['status']).to eq('running')
    expect(body['status_text']).to eq('执行中')
    expect(body['progress']).to be_between(0, 100)
    expect(body['running']).to be(true)

    unit = body['execution_units'].first
    expect(unit['device_name']).to eq(device.name)
    expect(unit['device_ip']).to eq('10.0.0.1')
    expect(unit['status']).to eq('completed')
    expect(unit['status_text']).to eq('已完成')

    s = unit['scripts'].first
    expect(s['name']).to eq(script.name)
    expect(s['status']).to eq('completed')
    expect(s['conclusion']).to eq('success')
    expect(s['logs']).to include('line1')
    expect(s['checkpoints'].first['name']).to eq('检查项')
    expect(s['duration']).to eq(1.23)
  end

  it '失败且带错误信息时脚本状态归为「执行异常」' do
    task.task_executions.create!(network_element_id: device.id, script_id: script.id,
                                 status: 'error', error_message: 'Connection refused',
                                 result: { 'conclusion' => 'error' })

    get status_task_path(task), headers: { 'Accept' => 'application/json' }
    unit = JSON.parse(response.body)['execution_units'].first
    s = unit['scripts'].first
    expect(s['status']).to eq('error')
    expect(s['error']).to eq('Connection refused')
  end
it 'POST /tasks/:id/reset 清空执行并回到 pending（JSON）' do
  run = task.task_runs.create!(status: 'completed', progress: 100)
  run.task_executions.create!(task: task, network_element_id: device.id, script_id: script.id,
                              status: 'completed', result: {})
  expect do
    post reset_task_path(task), headers: { 'Accept' => 'application/json' }
  end.to change(TaskExecution, :count).by(-1)

  expect(response).to have_http_status(:ok)
  expect(JSON.parse(response.body)['status']).to eq('pending')
  expect(task.reload.status).to eq('pending')
  expect(task.progress).to eq(0)
end

  it '运行中从 devlog 文件读取日志（持续刷新）' do
    run = task.task_runs.create!(status: 'running', progress: 0, started_at: Time.current)
    run.task_executions.create!(task: task, network_element_id: device.id, script_id: script.id,
                                status: 'running', logs: '')
    dir = "task_#{task.id}_#{run.started_at.strftime('%Y%m%d_%H%M%S')}"
    path = FilePathUtils.devlog_file_path(dir, device.ip_address, script.name,
                                          base_logs_dir: Rails.root.join('logs').to_s)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "line-1\nline-2\n")

    get status_task_path(task), headers: { 'Accept' => 'application/json' }
    s = JSON.parse(response.body)['execution_units'].first['scripts'].first
    expect(s['logs']).to include('line-1')
    expect(s['logs']).to include('line-2')
  ensure
    File.delete(path) if path && File.exist?(path)
  end

end

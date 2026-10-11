# frozen_string_literal: true

require 'rails_helper'
require_relative '../../app/services/fake_telnet_server_manager'
require_relative '../../app/services/task_runner'

# 真机执行链路（开源版把执行并入应用内）
#
# 用 FakeTelnetServer 当"真机"：起一个模拟设备，建脚本与任务，跑 TaskRunner，
# 断言执行结果与日志被正确记录。
RSpec.describe TaskRunner, type: :model do
  let(:user) { User.local_operator }
  let(:mapping) { [{ 'command' => 'show version', 'response' => 'VERSION-1.0' }] }
  let(:manager) { FakeTelnetServerManager.new(description: nil, command_mapping: mapping, port: 0) }
  let(:params) { manager.start }

  after { manager.stop }

  let(:device) do
    user.network_elements.create!(
      name: "dev-#{SecureRandom.hex(3)}", device_model: 'Smoke', active: true,
      ip_address: params[:host], port: params[:port], connection_type: 'telnet',
      username: params[:username], password: params[:password]
    )
  end

  let(:script) do
    user.scripts.create!(
      script_uid: Script.generate_unique_uid, name: "s-#{SecureRandom.hex(3)}",
      description: '冒烟脚本', version: '1.0.0', device_models: [], publish_status: :debugging,
      code: <<~RUBY
        class SpecTaskRunnerScript < Qingxun::DeviceScript
          def run(connection)
            out = connection.cli('show version')
            { command: 'show version', output: out }
          end
        end
      RUBY
    )
  end

  let(:task) do
    t = user.tasks.create!(name: "t-#{SecureRandom.hex(3)}", description: '冒烟任务')
    t.scripts = [script]
    t.network_elements = [device]
    t.device_count = 1
    t.script_count = 1
    t.save!
    t
  end

  it '在真实设备上执行脚本并记录结果、日志与状态' do
    described_class.new(task).call
    task.reload

    expect(task.status).to eq('completed')
    expect(task.progress).to eq(100)

    execution = task.task_executions.first
    expect(execution).not_to be_nil
    expect(execution.status).to eq('completed')
    expect(execution.result['output']).to include('VERSION-1.0')
    expect(execution.logs).to include('show version')
    expect(execution.duration_ms).to be_a(Integer)
  end

  it '设备不可达时把失败与错误记录下来，任务标记为 failed' do
    device.update!(ip_address: '127.0.0.1', port: 1) # 一个不会有人监听的端口
    described_class.new(task).call
    task.reload

    expect(task.status).to eq('failed')
    execution = task.task_executions.first
    expect(execution.status).to eq('failed')
    expect(execution.error_message).to be_present
  end
end

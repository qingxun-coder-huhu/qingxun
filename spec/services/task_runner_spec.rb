# frozen_string_literal: true

require 'rails_helper'
require_relative '../../app/services/fake_telnet_server_manager'
require_relative '../../app/services/task_runner'

# 任务执行（复用本地客户端的编排层：TaskExecutionCoordinator → DeviceExecutionProcessor → …）
#
# 语义与客户端一致：
#   - 任务状态 = **流程**是否跑完（所有单元处理完即 completed，不看巡检结论）；
#   - 脚本状态 = 巡检四态（completed/partial/failed/error），直接来自执行器；
#   - 不再有"运行中日志流"与"取消"（客户端编排层不提供）。
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
      code: <<~CODE
        class SpecTaskRunnerScript < Qingxun::DeviceScript
          def run(connection)
            out = connection.cli('show version')
            { command: 'show version', output: out }
          end
        end
      CODE
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

  it '跑完后任务状态为 completed，脚本行含状态、日志与检查点字段' do
    described_class.new(task).call
    task.reload

    expect(task.status).to eq('completed')
    expect(task.progress).to eq(100)

    execution = task.task_executions.first
    expect(execution).not_to be_nil
    expect(execution.status).to eq('completed')
    expect(execution.logs).to include('show version')
    expect(execution.result).to have_key('checkpoints')
  end

  it '设备不可达：任务流程仍算跑完，但脚本行记录失败与错误' do
    device.update!(ip_address: '127.0.0.1', port: 1) # 无人监听的端口
    described_class.new(task).call
    task.reload

    # 客户端语义：任务状态只回答"跑完了没有"，不看巡检结论
    expect(task.status).to eq('completed')
    execution = task.task_executions.first
    expect(%w[error failed]).to include(execution.status)
    expect(execution.error_message).to be_present
  end
  it '每次运行保留一条执行记录（1 任务 N 执行）' do
    2.times { described_class.new(task).call }
    task.reload

    expect(task.task_runs.count).to eq(2)
    expect(task.latest_run.status).to eq('completed')
    expect(task.task_executions.map(&:task_run_id).uniq.size).to eq(2)
  end

end

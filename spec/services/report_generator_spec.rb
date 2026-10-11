# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReportGenerator do
  let(:user) { User.local_operator }

  def build_device(name, ip)
    user.network_elements.create!(name: name, ip_address: ip, device_model: 'M',
                                  connection_type: 'telnet', username: 'a', password: 'x')
  end

  def build_script(name)
    user.scripts.create!(script_uid: Script.generate_unique_uid, name: name, description: 'x',
                         version: '1.0.0', device_models: [], publish_status: :debugging,
                         code: "class X < Qingxun::DeviceScript\n  def run(c); end\nend")
  end

  let(:device_ok) { build_device("ok-#{SecureRandom.hex(3)}", '10.0.0.1') }
  let(:device_bad) { build_device("bad-#{SecureRandom.hex(3)}", '10.0.0.2') }
  let(:script_a) { build_script('检查A') }
  let(:script_b) { build_script('检查B') }

  let(:task) do
    t = user.tasks.create!(name: "t-#{SecureRandom.hex(3)}", description: '巡检')
    t.scripts = [script_a, script_b]
    t.network_elements = [device_ok, device_bad]
    t.device_count = 2
    t.script_count = 2
    t.save!
    t
  end

  before do
    # device_ok：两个脚本都通过（带检查点）
    task.task_executions.create!(
      network_element_id: device_ok.id, script_id: script_a.id, status: 'completed',
      started_at: 10.seconds.ago, finished_at: 5.seconds.ago, logs: 'log-a',
      result: { 'conclusion' => 'success', 'checkpoints' => [{ 'name' => '根分区', 'passed' => true, 'value' => '22%' }] }
    )
    task.task_executions.create!(
      network_element_id: device_ok.id, script_id: script_b.id, status: 'completed',
      started_at: 4.seconds.ago, finished_at: Time.current, logs: 'log-b',
      result: { 'conclusion' => 'success', 'checkpoints' => [{ 'name' => '容器', 'passed' => true }] }
    )
    # device_bad：脚本A 部分通过、脚本B 连接失败
    task.task_executions.create!(
      network_element_id: device_bad.id, script_id: script_a.id, status: 'partial', logs: 'log-c',
      result: { 'conclusion' => 'partial', 'checkpoints' => [
        { 'name' => '磁盘', 'passed' => true },
        { 'name' => '进程', 'passed' => false, 'reason' => '未运行' }
      ] }
    )
    task.task_executions.create!(
      network_element_id: device_bad.id, script_id: script_b.id, status: 'error',
      error_message: 'Connection refused', result: { 'conclusion' => 'error' }
    )
    task.update_columns(status: 'completed', progress: 100, started_at: 20.seconds.ago, completed_at: Time.current)
  end

  it '产出与客户端一致的报告结构' do
    report = described_class.call(task)

    expect(report[:task][:name]).to eq(task.name)
    expect(report[:task][:duration]).to be_present

    stats = report[:statistics]
    expect(stats[:total_devices]).to eq(2)
    expect(stats[:total_scripts]).to eq(4)
    expect(stats[:all_success_devices]).to eq(1)   # 设备 ok
    expect(stats[:success_scripts]).to eq(2)       # 两个 all_passed
    expect(stats[:all_failed_devices]).to eq(0)    # bad 有一项 partial

    ok = report[:devices].find { |d| d[:id] == device_ok.id }
    expect(ok[:status]).to eq('completed')
    expect(ok[:scripts_success]).to eq(2)

    bad = report[:devices].find { |d| d[:id] == device_bad.id }
    expect(bad[:status]).to eq('failed')

    # 扁平列表带上设备字段
    flat = report[:flat_scripts]
    expect(flat.size).to eq(4)
    expect(flat.first).to include(:device_ip, :device_name, :device_model)

    # 检查点计数
    partial = flat.find { |s| s[:name] == script_a.name && s[:status] == 'partial' }
    expect(partial[:checkpoints_total]).to eq(2)
    expect(partial[:checkpoints_passed]).to eq(1)
    expect(partial[:checkpoints_failed]).to eq(1)
    expect(partial[:conclusion]).to eq('partial')

    # 错误汇总：连接失败那条
    expect(report[:errors].first[:error]).to eq('Connection refused')
  end

  it 'HTML 导出包含脚本名与检查点' do
    html = ReportHtmlGenerator.generate(task, described_class.call(task))
    expect(html).to include('任务报告')
    expect(html).to include('检查A')
    expect(html).to include('通过')
  end
end

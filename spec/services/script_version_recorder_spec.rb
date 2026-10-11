# frozen_string_literal: true

require 'rails_helper'

# 版本快照的写入策略：**版本由"描述"驱动**
#
# 背景：早先是"每次保存都留一条 + 高频来源节流合并"，结果是光改个脚本名字就一路留版本
# （实测：用户连敲 8 个字符，历史里冒出好几条）。现在改成：
#   - 主线描述或分支描述变了 → 新增一条版本（一条版本 = 一份需求的产物）；
#   - 名称/简介/代码/映射/型号/调试状态变了 → 只刷新当前版本，不新增；
#   - 内容与当前版本完全一致 → 连刷新都不做（免得白刷 updated_at）。
RSpec.describe ScriptVersionRecorder do
  let(:user) do
    u = User.new(
      email: "recorder_spec_#{SecureRandom.hex(6)}@example.com",
      password: 'password123',
      password_confirmation: 'password123'
    )
    u.save!(validate: false)
    u
  end

  let(:script) do
    Script.create!(
      name: '巡检脚本',
      description: '测试脚本',
      code: 'puts 1',
      initial_prompt: '检查设备版本',
      version: '1.0.0',
      device_models: ['ZXCTN 9000'],
      user_id: user.id
    )
  end

  def record(source: 'generated')
    described_class.record(script, source: source, user: user)
  end

  describe '描述变了才算新版本' do
    it '首次记录是 r1，并把 scripts.revision 游标推到 1' do
      version = record

      expect(version.revision).to eq(1)
      expect(version.source).to eq('generated')
      expect(version.user_id).to eq(user.id)
      expect(version.initial_prompt).to eq('检查设备版本')
      expect(script.reload.revision).to eq(1)
    end

    it '主线描述变化 → 新增 r2' do
      record
      script.update!(initial_prompt: '改过的需求：只看 CPU', code: 'puts 2')

      version = record(source: 'refined')

      expect(version.revision).to eq(2)
      expect(version.source).to eq('refined')
      expect(version.code).to eq('puts 2')
      expect(script.script_versions.count).to eq(2)
      expect(script.reload.revision).to eq(2)
    end

    it '分支描述变化 → 新增一版' do
      record
      script.update!(branch_scenarios: [
                       { 'name' => '分支1', 'description' => '端口全 up', 'command_mapping' => [], 'passed' => true }
                     ])

      version = record(source: 'refined')

      expect(version.revision).to eq(2)
      expect(script.script_versions.count).to eq(2)
    end
  end

  describe '描述没变时只刷新当前版本' do
    it '改代码/名称/简介/型号都不新增版本，只就地更新当前版本' do
      first = record
      script.update!(code: 'puts 2', name: '改过的名字', description: '改过的简介',
                     device_models: ['ZXCTN 9000', 'ZXCTN 9000-3'])

      refreshed = record(source: 'autosave')

      expect(refreshed.id).to eq(first.id)              # 还是同一条
      expect(refreshed.revision).to eq(1)               # 版本号没涨
      expect(script.script_versions.count).to eq(1)
      expect(refreshed.reload.code).to eq('puts 2')
      expect(refreshed.name).to eq('改过的名字')
      expect(script.reload.revision).to eq(1)           # 游标也没动
    end

    it '分支的映射与"通过与否"变了（描述没变）同样只刷新' do
      # 先带着分支记一版（新增分支本身属于描述变化），再只改映射与通过状态
      script.update!(branch_scenarios: [
                       { 'name' => '分支1', 'description' => '端口全 up',
                         'command_mapping' => [{ 'command' => 'show version', 'response' => 'ok' }],
                         'passed' => true }
                     ])
      record
      expect(script.script_versions.count).to eq(1)

      # 只有映射和通过状态变了 → 仍不是新版本
      script.update!(branch_scenarios: [
                       { 'name' => '分支1', 'description' => '端口全 up',
                         'command_mapping' => [{ 'command' => 'show version', 'response' => 'changed' }],
                         'passed' => false }
                     ])
      record(source: 'autosave')

      expect(script.script_versions.count).to eq(1)
    end

    it '标记调试完成（只变状态）只刷新当前版本' do
      first = record
      script.update!(publish_status: :debugged)

      refreshed = record(source: 'debugged')

      expect(refreshed.id).to eq(first.id)
      expect(refreshed.publish_status).to eq('debugged')
      expect(script.script_versions.count).to eq(1)
    end
  end

  describe '内容完全没变时不写库' do
    it '重复记录同一份内容不会刷新 updated_at' do
      first = record
      before = first.updated_at

      again = record(source: 'autosave')

      expect(again.id).to eq(first.id)
      expect(again.reload.updated_at).to eq(before)
      expect(script.script_versions.count).to eq(1)
    end
  end

  it '来源不在白名单时抛错，而不是写进一条无法归类的历史' do
    expect { record(source: 'something-else') }.to raise_error(ActiveRecord::RecordInvalid)
  end
end

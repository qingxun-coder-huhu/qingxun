# frozen_string_literal: true

require 'rails_helper'

# 脚本唯一标识 script_uid
#
# 背景：生成脚本页面初始化时确定 uid，随脚本入库；生成的脚本类名后缀与保存定位都用它，
# 因此它必须应用范围内唯一，且同一用户下允许存在同名脚本（名称不再是身份）。
RSpec.describe Script, type: :model do
  let(:user) do
    u = User.new(
      email: "script_spec_#{SecureRandom.hex(6)}@example.com",
      password: 'password123',
      password_confirmation: 'password123'
    )
    u.save!(validate: false)
    u
  end

  def build_script(overrides = {})
    Script.new({
      name: '巡检脚本',
      description: '测试脚本',
      code: 'class DemoS < Qingxun::DeviceScript; end',
      version: '1.0.0',
      device_models: ['ZXCTN 9000'],
      user_id: user.id
    }.merge(overrides))
  end

  describe 'script_uid 生成' do
    it '创建时自动生成 16 位十六进制标识' do
      script = build_script
      script.save!

      expect(script.script_uid).to match(/\A[0-9a-f]{16}\z/)
    end

    it '显式指定的标识会被保留（页面初始化时已确定）' do
      uid = SecureRandom.hex(8)
      script = build_script(script_uid: uid)
      script.save!

      expect(script.reload.script_uid).to eq(uid)
    end

    it '多个脚本的标识互不相同' do
      uids = Array.new(5) { build_script.tap(&:save!).script_uid }
      expect(uids.uniq.length).to eq(5)
    end

    it '标识必须唯一' do
      uid = SecureRandom.hex(8)
      build_script(script_uid: uid).save!
      dup = build_script(name: '另一个脚本', script_uid: uid)

      expect(dup).not_to be_valid
      expect(dup.errors[:script_uid]).not_to be_empty
    end

    it '标识格式必须是 16 位十六进制' do
      expect(build_script(script_uid: 'ABC')).not_to be_valid
    end
  end

  describe '允许同名脚本（名称不再唯一）' do
    it '同一用户下可以保存两个同名脚本' do
      first = build_script(name: '重名脚本')
      second = build_script(name: '重名脚本')

      expect(first.save).to be true
      expect(second.save).to be true
      expect(user.scripts.where(name: '重名脚本').count).to eq(2)
      expect(first.script_uid).not_to eq(second.script_uid)
    end
  end

  describe '#create_new_version' do
    it '复制出的新版本会获得新的标识，不与原脚本共用' do
      original = build_script
      original.save!

      new_version = original.create_new_version

      expect(new_version.script_uid).to match(/\A[0-9a-f]{16}\z/)
      expect(new_version.script_uid).not_to eq(original.script_uid)
      expect(new_version.parent_script_id).to eq(original.id)
    end
  end

  # 命令映射支持嵌套的上下文树：命中带 children 的命令进入下一层，同一命令在不同
  # 上下文下可有不同回显。mock 是仅模拟服务器使用的导航元数据（真机不生效）。
  describe 'command_mapping 嵌套校验' do
    def mapping_errors(mapping)
      build_script(command_mapping: mapping).tap(&:valid?).errors[:command_mapping]
    end

    it '接受平铺映射' do
      expect(mapping_errors([{ 'command' => 'show version', 'response' => 'v1' }])).to be_empty
    end

    it '接受带 children 的嵌套映射' do
      mapping = [{
        'command' => 'switch board 1',
        'response' => '',
        'children' => [
          { 'command' => 'ls', 'response' => 'card1' },
          { 'command' => 'exit', 'response' => '', 'mock' => { 'exit_level' => 1 } }
        ]
      }]

      expect(mapping_errors(mapping)).to be_empty
    end

    it '接受 exit_level 为 0（回根上下文）' do
      mapping = [{
        'command' => 'enter', 'response' => '',
        'children' => [{ 'command' => 'exit', 'response' => '', 'mock' => { 'exit_level' => 0 } }]
      }]

      expect(mapping_errors(mapping)).to be_empty
    end

    it '拒绝 response 非字符串' do
      expect(mapping_errors([{ 'command' => 'x', 'response' => 123 }])).not_to be_empty
    end

    it '拒绝缺 command/response 键的节点' do
      expect(mapping_errors([{ 'command' => 'x' }])).not_to be_empty
    end

    it '拒绝负数 exit_level' do
      mapping = [{ 'command' => 'exit', 'response' => '', 'mock' => { 'exit_level' => -1 } }]
      expect(mapping_errors(mapping)).not_to be_empty
    end

    # 提示符因设备而异，映射里不该有它；mock.prompt 已删除，旧数据里残留也不会被当回事
    it '忽略 mock 里已删除的 prompt 字段（不再校验、不再报错）' do
      mapping = [{ 'command' => 'enter', 'response' => '', 'mock' => { 'prompt' => 'board1' } }]
      expect(mapping_errors(mapping)).to be_empty
    end

    it '拒绝 children 不是数组' do
      mapping = [{ 'command' => 'enter', 'response' => '', 'children' => 'ls' }]
      expect(mapping_errors(mapping)).not_to be_empty
    end

    it '拒绝嵌套层级过深' do
      node = { 'command' => 'leaf', 'response' => '' }
      12.times { |i| node = { 'command' => "level#{i}", 'response' => '', 'children' => [node] } }

      expect(mapping_errors([node])).not_to be_empty
    end
  end

  # 型号是脚本与设备匹配的依据，所以要求它卡在"能不能被任务选中"那一关（调试完成），
  # 而不是卡在草稿阶段——生成脚本页是先生成代码、后填型号，草稿要能先存下来
  describe '设备型号的必填时机' do
    it '草稿（调试中）允许没有型号' do
      script = build_script(device_models: [], publish_status: :debugging)

      expect(script).to be_valid
    end

    it '标记调试完成时必须给出型号' do
      script = build_script(device_models: [], publish_status: :debugged)

      expect(script).to be_invalid
      expect(script.errors[:device_models].join).to include('调试完成')
    end

    it '调试完成且型号非空时正常通过' do
      expect(build_script(device_models: ['ZXCTN 9000'], publish_status: :debugged)).to be_valid
    end
  end
end

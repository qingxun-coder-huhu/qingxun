# frozen_string_literal: true

require 'rails_helper'

# 脚本版本快照
#
# 背景：脚本内容每次有意义的变更都留一条快照，页面的历史列表与回滚都读它。
# 这里钉住三件容易写错的事：
#   1. source 必须在白名单内——页面按 source 归类显示，写成自由文本，历史列表就会退化成一串
#      "某次保存"，用户看不出哪条是生成、哪条是回滚；
#   2. revision 在同一脚本内唯一（DB 有 [script_id, revision] 唯一索引，模型层也要拦住）；
#   3. same_content? 要忽略 JSON 键顺序，否则同一份内容（DB 回读 vs 参数解析）会被判成"变了"，
#      自动保存每次都白记一条。
RSpec.describe ScriptVersion, type: :model do
  let(:user) do
    u = User.new(
      email: "script_version_spec_#{SecureRandom.hex(6)}@example.com",
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
      code: 'class DemoS < Qingxun::DeviceScript; end',
      initial_prompt: '检查设备版本',
      version: '1.0.0',
      device_models: ['ZXCTN 9000'],
      user_id: user.id
    )
  end

  def build_version(overrides = {})
    ScriptVersion.new({
      script: script,
      user: user,
      revision: 1,
      source: 'generated',
      name: script.name,
      description: script.description,
      code: script.code,
      initial_prompt: script.initial_prompt,
      publish_status: script.publish_status,
      command_mapping: {},
      device_models: [],
      branch_scenarios: []
    }.merge(overrides))
  end

  describe '校验' do
    it '合法快照可以保存，并能给出给用户看的来源说明' do
      version = build_version
      version.save!

      expect(version).to be_persisted
      expect(version.source_label).to eq('自动生成')
    end

    it '来源必须在白名单内' do
      expect(build_version(source: 'whatever')).to be_invalid
      expect(build_version(source: 'autosave')).to be_valid
    end

    it '同一脚本内 revision 不能重复，不同脚本可以各自从 1 开始' do
      build_version.save!
      expect(build_version(revision: 1)).to be_invalid

      other = Script.create!(
        name: '另一个脚本', description: 'x', code: 'class X; end',
        version: '1.0.0', device_models: [], user_id: user.id
      )
      expect(build_version(script: other, revision: 1)).to be_valid
    end

    it 'revision 必须是正整数' do
      expect(build_version(revision: 0)).to be_invalid
      expect(build_version(revision: -1)).to be_invalid
    end
  end

  describe '#same_content?' do
    let(:version) do
      build_version(command_mapping: { 'commands' => [{ 'command' => 'show version' }] },
                    device_models: ['ZXCTN 9000'])
    end

    it '内容一致（含 JSON 键顺序不同）时判定为相同' do
      same = {
        name: version.name,
        description: version.description,
        code: version.code,
        initial_prompt: version.initial_prompt,
        publish_status: version.publish_status,
        command_mapping: { 'commands' => [{ 'command' => 'show version' }] },
        device_models: ['ZXCTN 9000'],
        branch_scenarios: []
      }
      expect(version.same_content?(same)).to be(true)

      reordered = { 'commands' => [{ 'command' => 'show version' }] }
      expect(version.same_content?(same.merge(command_mapping: reordered))).to be(true)
    end

    it '代码、名称或调试状态变了就判定为不同' do
      base = {
        name: version.name, description: version.description, code: version.code,
        initial_prompt: version.initial_prompt,
        publish_status: version.publish_status,
        command_mapping: version.command_mapping, device_models: version.device_models,
        branch_scenarios: []
      }
      expect(version.same_content?(base.merge(code: 'class X; end'))).to be(false)
      expect(version.same_content?(base.merge(name: '改过名字'))).to be(false)
      # 「标记调试完成」内容没变、只有状态变，也必须算变化，否则这条历史会被去重吞掉
      expect(version.same_content?(base.merge(publish_status: 'debugged'))).to be(false)
      # 主线描述变了同样是变化（它进快照了，否则改了需求不会留痕）
      expect(version.same_content?(base.merge(initial_prompt: '另一条需求'))).to be(false)
    end
  end

  it 'recent 按 revision 倒序' do
    build_version(revision: 1).save!
    build_version(revision: 3).save!
    build_version(revision: 2).save!

    expect(script.script_versions.recent.map(&:revision)).to eq([3, 2, 1])
  end
end

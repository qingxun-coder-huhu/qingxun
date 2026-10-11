# frozen_string_literal: true

require 'rails_helper'

# 两版差异（页面"与上一版的差异"）
#
# 背景：版本由"描述"驱动（主线描述或分支描述变化才新增版本），所以差异的主角是描述：
# 分支描述是用户最关心的（新增/删除/修改），主线描述给行级差异；其余字段只报"变了没变"。
# 这里不落库，直接构造两个 ScriptVersion 实例比较（比较逻辑只读属性）。
RSpec.describe ScriptVersionDiff do
  def version(overrides = {})
    ScriptVersion.new({
      revision: 1,
      source: 'generated',
      name: '巡检脚本',
      description: '测试脚本',
      code: "puts 1\nputs 2",
      initial_prompt: "目标：核对端口状态\n预期：列出非 connected 端口",
      command_mapping: {},
      device_models: ['ZXCTN 9000'],
      branch_scenarios: [],
      publish_status: 'debugging'
    }.merge(overrides))
  end

  describe '没有上一版时' do
    it '只回 first 标记' do
      diff = described_class.new(nil, version(revision: 3)).to_h

      expect(diff[:first]).to be(true)
      expect(diff[:to_revision]).to eq(3)
    end
  end

  describe '分支描述（重点）' do
    it '修改：同名的分支描述变了 → changed 里给旧值→新值' do
      before = version(branch_scenarios: [{ 'name' => '分支A', 'description' => '端口全 up', 'passed' => true }])
      after = version(revision: 2,
                      branch_scenarios: [{ 'name' => '分支A', 'description' => '端口有 down', 'passed' => true }])

      branches = described_class.new(before, after).to_h[:branches]

      expect(branches[:changed]).to eq([{ name: '分支A', before: '端口全 up', after: '端口有 down' }])
      expect(branches[:added]).to be_empty
      expect(branches[:removed]).to be_empty
      expect(branches[:unchanged_count]).to eq(0)
    end

    it '新增与删除：按分支名归类' do
      before = version(branch_scenarios: [{ 'name' => '分支A', 'description' => '端口全 up' },
                                          { 'name' => '分支B', 'description' => '旧场景' }])
      after = version(revision: 2,
                      branch_scenarios: [{ 'name' => '分支A', 'description' => '端口全 up' },
                                         { 'name' => '分支C', 'description' => '新场景' }])

      branches = described_class.new(before, after).to_h[:branches]

      expect(branches[:added]).to eq([{ name: '分支C', description: '新场景' }])
      expect(branches[:removed]).to eq([{ name: '分支B', description: '旧场景' }])
      expect(branches[:changed]).to be_empty
      expect(branches[:unchanged_count]).to eq(1)
    end

    it '只有命令映射与通过与否变了（描述没变）→ 不算差异' do
      before = version(branch_scenarios: [{ 'name' => '分支A', 'description' => '端口全 up',
                                            'command_mapping' => [{ 'command' => 'show version', 'response' => 'ok' }],
                                            'passed' => true }])
      after = version(revision: 2,
                      branch_scenarios: [{ 'name' => '分支A', 'description' => '端口全 up',
                                           'command_mapping' => [{ 'command' => 'show version', 'response' => 'changed' }],
                                           'passed' => false }])

      branches = described_class.new(before, after).to_h[:branches]

      expect(branches[:changed]).to be_empty
      expect(branches[:added]).to be_empty
      expect(branches[:removed]).to be_empty
      expect(branches[:unchanged_count]).to eq(1)
    end

    # 名称为空的分支只能拿描述当身份，于是描述一改就被报成"删一个 + 加一个"（当前行为，
    # 页面上分支都带名字，这种退化形态很少遇到）
    it '分支没有名字时按描述匹配：描述改了会被报成删除+新增' do
      before = version(branch_scenarios: [{ 'name' => '', 'description' => '端口全 up' }])
      after = version(revision: 2, branch_scenarios: [{ 'name' => '', 'description' => '端口有 down' }])

      branches = described_class.new(before, after).to_h[:branches]

      # 无名字 → 用描述当身份 → 描述一变，身份也变了，会归为 removed + added（记录当前行为）
      expect(branches[:removed].size + branches[:added].size).to eq(2)
      expect(branches[:changed]).to be_empty
    end

    it '两版都没有分支时，三类都空' do
      branches = described_class.new(version, version(revision: 2)).to_h[:branches]

      expect(branches[:added]).to be_empty
      expect(branches[:removed]).to be_empty
      expect(branches[:changed]).to be_empty
      expect(branches[:unchanged_count]).to eq(0)
    end
  end

  describe '主线描述的行级差异' do
    it '没变时 changed 为 false，且全部是 same' do
      mainline = described_class.new(version, version(revision: 2)).to_h[:mainline]

      expect(mainline[:changed]).to be(false)
      expect(mainline[:lines].map { |op| op[:op] }.uniq).to eq(['same'])
    end

    it '改了一行时给出 removed + added，未变行保持 same' do
      after = version(revision: 2, initial_prompt: "目标：核对端口状态\n预期：列出非 connected 端口（含 down）")
      mainline = described_class.new(version, after).to_h[:mainline]

      expect(mainline[:changed]).to be(true)
      expect(mainline[:lines]).to eq([
                                       { op: 'same', text: '目标：核对端口状态' },
                                       { op: 'removed', text: '预期：列出非 connected 端口' },
                                       { op: 'added', text: '预期：列出非 connected 端口（含 down）' }
                                     ])
    end
  end

  describe '其他字段与代码' do
    it '只列出真正变了的字段（名称/简介/型号/状态），空值有兜底' do
      before = version(name: '旧名', description: '旧简介', device_models: ['A'], publish_status: 'debugging')
      after = version(revision: 2, name: '新名', description: '旧简介', device_models: [],
                      publish_status: 'debugged')

      fields = described_class.new(before, after).to_h[:fields]

      expect(fields).to eq([
                             { label: '脚本名称', before: '旧名', after: '新名' },
                             { label: '设备型号', before: 'A', after: '' },
                             { label: '调试状态', before: '调试中', after: '调试完成' }
                           ])
    end

    it '代码变化给增删行数与该行级差异' do
      after = version(revision: 2, code: "puts 1\nputs 3")
      code = described_class.new(version, after).to_h[:code]

      expect(code[:changed]).to be(true)
      expect(code[:added]).to eq(1)
      expect(code[:removed]).to eq(1)
      expect(code[:lines]).to include({ op: 'removed', text: 'puts 2' }, { op: 'added', text: 'puts 3' })
    end

    it '代码没变时 changed 为 false' do
      code = described_class.new(version, version(revision: 2)).to_h[:code]

      expect(code[:changed]).to be(false)
      expect(code[:added]).to eq(0)
      expect(code[:removed]).to eq(0)
    end
  end
end

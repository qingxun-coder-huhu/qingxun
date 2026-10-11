# frozen_string_literal: true

# ScriptVersionDiff 算两版之间的差异（页面上"与上一版的差异"用它）。
#
# 业务逻辑：
#   版本由"描述"驱动（见 ScriptVersionRecorder），所以差异的主角就是**描述**：
#   - 分支描述按分支归为「新增 / 删除 / 修改」三类（用户最关心的就是这一块）；
#   - 主线描述逐行对比，给出可读的行级差异；
#   - 名称、脚本简介、设备型号、调试状态只报"变了没变"（旧值 → 新值）；
#   - 代码给行级差异 + 增删行数，页面默认折叠（两版之间代码常常整体重写，铺开会淹没描述差异）。
#
# 隐性知识：
#   1. 分支的身份用**名称**（页面上分支标签就是名称），所以"改了描述"能报成「修改」而不是
#      「删一个 + 加一个」。名称为空的分支只能拿描述当身份，于是它的描述一改就会被报成删除+新增
#      （见 spec 里那条用例）——分支在页面上都带名字，这种退化形态实际很少遇到。
#      名称重复时后出现的覆盖先出现的：分支重名本来就该由用户避免，这里不再兜。
#   2. 行级对比自己实现（LCS）：不能用 diff-lcs，它只是 rspec 的传递依赖，生产镜像
#      BUNDLE_WITHOUT=development:test 时不安装，写进 app 代码会在生产直接崩。
#   3. 差异是"上一版 → 这一版"单向的：页面按 revision 倒序展示，点哪一版就看它与前一版的差异。
class ScriptVersionDiff
  # 分支在差异里的身份与展示信息
  Branch = Struct.new(:key, :name, :description, keyword_init: true)

  def initialize(before, after)
    @before = before
    @after = after
  end

  def to_h
    return { first: true, to_revision: @after.revision } if @before.nil?

    {
      first: false,
      from_revision: @before.revision,
      to_revision: @after.revision,
      branches: branch_changes,
      mainline: {
        changed: @before.initial_prompt.to_s != @after.initial_prompt.to_s,
        lines: line_ops(@before.initial_prompt, @after.initial_prompt)
      },
      fields: field_changes,
      code: {
        changed: code_changed?,
        added: code_ops.count { |op| op[:op] == 'added' },
        removed: code_ops.count { |op| op[:op] == 'removed' },
        lines: code_ops
      }
    }
  end

  private

  def branch_changes
    old_by_key = branch_list(@before.branch_scenarios).index_by(&:key)
    new_by_key = branch_list(@after.branch_scenarios).index_by(&:key)

    added = (new_by_key.keys - old_by_key.keys).map { |key| branch_json(new_by_key[key]) }
    removed = (old_by_key.keys - new_by_key.keys).map { |key| branch_json(old_by_key[key]) }
    changed = (new_by_key.keys & old_by_key.keys).filter_map do |key|
      old_branch = old_by_key[key]
      new_branch = new_by_key[key]
      next if old_branch.description == new_branch.description

      { name: new_branch.name, before: old_branch.description, after: new_branch.description }
    end

    {
      added: added,
      removed: removed,
      changed: changed,
      unchanged_count: (new_by_key.keys & old_by_key.keys).size - changed.size
    }
  end

  def branch_list(scenarios)
    Array(scenarios).map do |scenario|
      if scenario.is_a?(Hash)
        name = scenario['name'].to_s
        description = scenario['description'].to_s
        Branch.new(key: name.empty? ? "desc:#{description}" : "name:#{name}",
                   name: name.empty? ? '未命名分支' : name,
                   description: description)
      else
        # 容忍早期/异常形态：非 Hash 的分支当纯描述处理
        Branch.new(key: "desc:#{scenario}", name: '未命名分支', description: scenario.to_s)
      end
    end
  end

  def branch_json(branch)
    { name: branch.name, description: branch.description }
  end

  def field_changes
    [
      { label: '脚本名称', before: @before.name.to_s, after: @after.name.to_s },
      { label: '脚本简介', before: @before.description.to_s, after: @after.description.to_s },
      { label: '设备型号', before: Array(@before.device_models).join('、'),
        after: Array(@after.device_models).join('、') },
      { label: '调试状态', before: status_label(@before.publish_status),
        after: status_label(@after.publish_status) }
    ].select { |field| field[:before] != field[:after] }
  end

  def status_label(status)
    status.to_s == 'debugged' ? '调试完成' : '调试中'
  end

  def code_ops
    @code_ops ||= line_ops(@before.code, @after.code)
  end

  def code_changed?
    code_ops.any? { |op| op[:op] != 'same' }
  end

  # 行级差异（LCS）。nil 与空串都当"没有内容"。
  def line_ops(before_text, after_text)
    old_lines = before_text.to_s.lines(chomp: true)
    new_lines = after_text.to_s.lines(chomp: true)

    lcs = Array.new(old_lines.size + 1) { Array.new(new_lines.size + 1, 0) }
    (old_lines.size - 1).downto(0) do |i|
      (new_lines.size - 1).downto(0) do |j|
        lcs[i][j] = if old_lines[i] == new_lines[j]
                      lcs[i + 1][j + 1] + 1
                    else
                      [lcs[i + 1][j], lcs[i][j + 1]].max
                    end
      end
    end

    ops = []
    i = 0
    j = 0
    while i < old_lines.size && j < new_lines.size
      if old_lines[i] == new_lines[j]
        ops << { op: 'same', text: old_lines[i] }
        i += 1
        j += 1
      elsif lcs[i + 1][j] >= lcs[i][j + 1]
        ops << { op: 'removed', text: old_lines[i] }
        i += 1
      else
        ops << { op: 'added', text: new_lines[j] }
        j += 1
      end
    end
    while i < old_lines.size
      ops << { op: 'removed', text: old_lines[i] }
      i += 1
    end
    while j < new_lines.size
      ops << { op: 'added', text: new_lines[j] }
      j += 1
    end
    ops
  end
end

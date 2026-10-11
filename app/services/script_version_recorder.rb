# frozen_string_literal: true

# ScriptVersionRecorder 把脚本当前内容写进版本历史。
#
# 业务逻辑（**版本由"描述"驱动**）：
#   一份版本 = 一份需求的产物。所以只有**主线描述**或**分支描述**变化时，才封存上一版、开一条
#   新版本；名称、脚本描述简介、代码、命令映射、设备型号、调试状态都属于"同一份需求下的产物"，
#   变化时**只刷新当前版本**，不新增历史。
#
# 隐性知识：
#   1. 为什么这样切：早先是"每次保存都留一条 + 高频来源节流合并"，结果是**光改个脚本名字就一路
#      留版本**（实测：用户连敲 8 个字符，历史里冒出好几条，他直接问"没动作怎么会自动保存"）。
#      按"描述"切分后，历史里每一条都对应一次需求变更，用户能一眼对上"我什么时候改了需求"。
#   2. 名字/代码/状态变了只刷新当前版本，意味着**同一份需求下回不到"上一份代码"**——这是这个
#      模型接受的代价（想留旧代码就改描述，或先把脚本复制一份）。
#   3. 与当前版本内容完全一致时不写库：否则碰一下输入框就会刷一次 updated_at，白写一次。
#   4. revision 以 scripts.revision 为游标递增（再取现存最大值兜底）；DB 上有
#      [script_id, revision] 唯一索引，真撞了会抛异常而不是静默覆盖。
#   5. 用 update_column 推进游标：只改这一列，不触发回调、也不动 scripts.updated_at。
class ScriptVersionRecorder
  def self.record(script, source:, user: nil)
    new(script, source: source, user: user).record
  end

  def initialize(script, source:, user: nil)
    @script = script
    @source = source.to_s
    @user = user || script.user
  end

  # 返回被写入（或就地刷新）的那条版本记录
  def record
    current = @script.script_versions.recent.first
    attrs = snapshot_attributes

    if current
      # 描述没变 → 这份产物仍属于当前版本，就地刷新；连内容都没变就完全不写库
      return current if current.same_spec?(attrs) && current.same_content?(attrs)

      if current.same_spec?(attrs)
        current.update!(attrs)
        return current
      end
    end

    version = @script.script_versions.create!(
      attrs.merge(user_id: @user&.id, revision: next_revision(current), source: @source)
    )
    @script.update_column(:revision, version.revision)
    version
  end

  private

  def snapshot_attributes
    {
      name: @script.name,
      description: @script.description,
      code: @script.code,
      # 主线描述是版本的主键之一（见 ScriptVersion#same_spec?）
      initial_prompt: @script.initial_prompt,
      command_mapping: @script.command_mapping || {},
      device_models: @script.device_models || [],
      # 分支场景整体存：分支描述参与"是否算新版本"的判断，命令映射与通过与否只是产物
      branch_scenarios: @script.branch_scenarios || [],
      publish_status: @script.publish_status
    }
  end

  def next_revision(current)
    [@script.revision.to_i, current&.revision.to_i].max + 1
  end
end

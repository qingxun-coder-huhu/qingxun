# frozen_string_literal: true

# 把 network_elements 的主键从 integer 改回 UUID 字符串
#
# 背景：这是一次被「按 schema.rb 重建库」弄丢的类型转换。
#   迁移 20260217194000_change_network_elements_id_to_uuid 本意就是把主键改成 UUID 字符串，
#   它已记录在 schema_migrations 里；从表 task_network_elements.network_element_id 现在也确实
#   是 character varying。但主表的主键仍是 integer（db/schema.rb 里写着 id: :serial），
#   说明某次用 schema.rb 重建数据库时把主键建回了整数，而迁移记录被保留了下来 ——
#   于是 db:migrate 认为它已执行，再也不会修正这个偏差。
#
# 后果（实测）：客户端同步时把自己的设备 UUID 当 id 发上来，整数列会取 UUID 字符串开头的
#   数字（String#to_i）：以 a–f 开头的变成 0，以数字开头的变成那串数字（如 60199122）。
#   多条记录的 id 都落到 0 → 主键唯一约束冲突 → 同步第 2 台就失败。模型侧本来就写着
#   `before_validation :generate_uuid`（`self.id ||= SecureRandom.uuid`），即代码一直是按
#   UUID 语义设计的，只有列类型没跟上。
#
# 隐知识：
#   1. 用 :string 而不是原生 uuid 类型，是为了与从表 task_network_elements.network_element_id
#      （character varying）保持一致，也符合原迁移的写法（`t.change :id, :string`）。
#   2. 存量行只有极少数（本机 1 行、任务关联 0 行），直接为每行生成新 UUID 并回填引用即可，
#      不需要保留旧的整数值 —— 旧值本身就是转换失败的产物，没有保留价值。
#   3. 不新增 task_network_elements → network_elements 的外键：原迁移当时刻意移除了它，
#      本次只修类型，不改变约束现状。
#   4. **必须按当前列类型分岔**：生产库的 id 本来就是 string（原迁移在那里生效了），
#      只有本地开发库/测试库因按 schema.rb 重建而退回 integer。若无条件执行，生产上会把
#      一个已经正确的、客户端认识的 UUID 换成随机新值 —— 那是没必要的线上数据改写。
#      所以已是字符串时直接跳过，只清理原迁移漏掉的自增默认值。
class FixNetworkElementsIdToUuid < ActiveRecord::Migration[7.1]
  def up
    id_column = connection.columns(:network_elements).find { |c| c.name == "id" }

    # —— 已经是字符串主键：跳过转换，只清历史遗留 ——
    if id_column && id_column.type != :integer
      # 原 UUID 迁移只改了类型，没清掉 serial 留下的默认值，
      # 于是在字符串主键上留着 nextval(...)：若有代码不显式给 id 建行，会得到一个数字串。
      # 模型侧有 `self.id ||= SecureRandom.uuid` 兜着，但默认值本身是无意义的，清掉。
      # 隐性知识：Rails 对序列默认值**不填 default 而填 default_function**
      # （如 nextval('network_elements_id_seq'::regclass)），只看 .default 会漏掉，
      # 这两个都要判。线上首跑时就是因为只看了 .default，这句清理没有触发。
      if id_column.default.present? || id_column.default_function.present?
        execute "ALTER TABLE network_elements ALTER COLUMN id DROP DEFAULT"
        execute "DROP SEQUENCE IF EXISTS network_elements_id_seq"
        say "已清理 network_elements.id 上遗留的自增默认值"
      end
      say "network_elements.id 已是 #{id_column.type}，跳过 UUID 转换"
      return
    end

    # —— 主键仍是整数：执行转换 ——
    # 1. 新增临时列
    add_column :network_elements, :uuid_id, :string

    # 2. 为存量行生成 UUID（gen_random_uuid 为 PostgreSQL 13+ 内置）
    execute "UPDATE network_elements SET uuid_id = gen_random_uuid()::text"

    # 3. 任务关联里的引用从旧整数（字符串形式）改指到新 UUID。
    #    已经是 UUID 形式（对不上任何旧 id::text）的行保持原样。
    execute <<~SQL
      UPDATE task_network_elements tne
         SET network_element_id = ne.uuid_id
        FROM network_elements ne
       WHERE tne.network_element_id = ne.id::text
    SQL

    # 4. 换主键：删旧列（主键约束随之删除）→ 改名 → 补非空 → 重建主键
    remove_column :network_elements, :id
    rename_column :network_elements, :uuid_id, :id
    change_column_null :network_elements, :id, false
    execute "ALTER TABLE network_elements ADD CONSTRAINT network_elements_pkey PRIMARY KEY (id)"

    # 5. 旧自增序列已无用途（删列时通常随属主列一并删除，这里兜底）
    execute "DROP SEQUENCE IF EXISTS network_elements_id_seq"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, <<~MSG
      无法回退：主键已是 UUID，原有的自增整数值在转换时未保留（它们本身就是类型不匹配的产物），
      无法还原；且回退会重新引入「客户端 UUID 存不进整数列 → 同步第 2 台失败」的故障。
    MSG
  end
end

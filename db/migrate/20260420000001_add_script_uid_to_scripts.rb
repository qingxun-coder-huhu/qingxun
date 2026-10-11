# frozen_string_literal: true

require 'securerandom'

# 为脚本增加「唯一标识」script_uid
#
# 业务逻辑：
#   生成脚本页面在初始化时确定一个 script_uid：新脚本新生成，加载老脚本沿用其值。
#   该值随脚本一起入库，作为脚本在**整个应用范围内**的唯一标识；生成出的脚本类名
#   后缀也由它派生（原类名_<uid>），并据此保存（不再依赖脚本名称唯一）。
#
# 隐性知识：
#   1. 历史数据必须回填：先加可空列 → 逐行回填 16 位十六进制 → 再置 NOT NULL 并加唯一索引。
#   2. 回填用本地 Set 去重，避免 8 字节随机在极小概率下撞车导致唯一索引创建失败。
#   3. 同一用户允许存在同名脚本，因此删除 scripts(user_id, name) 唯一索引；
#      名称不再作为身份，身份由 script_uid 承担。
#   4. down 时重新加回 name 唯一索引，若此时已存在同名脚本会失败（属预期）。
class AddScriptUidToScripts < ActiveRecord::Migration[7.1]
  def up
    add_column :scripts, :script_uid, :string, comment: '脚本唯一标识（页面初始化时确定，类名后缀同此值）'

    say_with_time '回填 scripts.script_uid' do
      Script.reset_column_information
      used = Set.new
      Script.find_each do |script|
        uid = loop do
          candidate = SecureRandom.hex(8)
          break candidate unless used.include?(candidate)
        end
        used << uid
        script.update_columns(script_uid: uid)
      end
    end

    change_column_null :scripts, :script_uid, false
    add_index :scripts, :script_uid, unique: true
    remove_index :scripts, name: 'index_scripts_on_user_id_and_name'
  end

  def down
    add_index :scripts, [:user_id, :name], unique: true, name: 'index_scripts_on_user_id_and_name'
    remove_index :scripts, :script_uid
    remove_column :scripts, :script_uid
  end
end

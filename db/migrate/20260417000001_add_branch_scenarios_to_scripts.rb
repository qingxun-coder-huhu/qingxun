# frozen_string_literal: true

# 为脚本增加「分支覆盖」测试场景
#
# 业务逻辑：
#   一条主线描述生成一份脚本代码，再为若干分支场景各生成一份命令-报文映射，
#   让同一份代码在每个分支场景下分别跑沙盒测试。全部分支（含主线）通过才算通过。
#
# 隐性知识：
#   1. 分支只存「名称 + 全量描述 + 该分支的命令映射 + 是否通过」，用于页面回填与复现。
#   2. 与 command_mapping 一样用 json 列，默认空数组，保证旧脚本无缝升级。
class AddBranchScenariosToScripts < ActiveRecord::Migration[7.1]
  def change
    add_column :scripts, :branch_scenarios, :json, default: [], comment: '分支覆盖测试场景（名称/描述/命令映射/通过与否）'
  end
end

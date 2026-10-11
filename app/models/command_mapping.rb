# frozen_string_literal: true

# 命令映射模型
#
# 业务逻辑：
# CommandMapping模型代表脚本的一组命令映射配置，包含用户输入的命令和响应示例、
# 自动生成的映射文件、沙盒调试日志以及调试执行结果。
# 一个脚本可以对应多组命令映射，方便用户测试不同的场景。
#
# 隐性知识：
# 1. prompt字段存储用户输入的命令和响应示例以及预期结果
# 2. mapping_file字段存储AI自动生成的命令映射文件内容
# 3. sandbox_debug_log字段存储沙盒调试过程中的日志
# 4. debug_execution_result字段存储调试执行的结果
#
class CommandMapping < ApplicationRecord
  belongs_to :script
end

# frozen_string_literal: true

# Qingxun 网络设备自动化框架主模块。
# 该框架提供了设备连接管理、脚本执行、任务编排和结构化日志记录功能。
#
# 使用示例：
#   require 'qingxun'
#   result = Qingxun::TaskManager.run('path/to/task.json')
#
# 或者单独使用组件：
#   require 'qingxun/device_script'
#   class MyScript < Qingxun::DeviceScript
#     def run(connection)
#       # 你的代码
#     end
#   end
#
module Qingxun
  # 框架版本号
  VERSION = '0.1.0'
end

# 加载核心组件
require_relative 'qingxun/device_script'
require_relative 'qingxun/connection_factory'
require_relative 'qingxun/logger'
require_relative 'qingxun/device_executor'
require_relative 'qingxun/task_manager'
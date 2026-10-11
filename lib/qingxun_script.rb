# frozen_string_literal: true

# QingxunScript 模块用于存放所有生成的设备脚本类
# 这个命名空间用于区分用户自定义脚本和 AI 生成的脚本
#
# 业务逻辑背景：
# - 为了更好地区分通过 ScriptGenerationService 生成的脚本和手动编写的脚本
# - 将所有生成的脚本放在统一的命名空间下，便于管理和加载
# - 保持与 Qingxun 框架的命名一致性
#
# 隐性知识：
# - 这个模块本身不包含业务逻辑，仅作为命名空间容器
# - 所有通过 AI 生成的脚本类都应该定义在 QingxunScript 模块内部
# - 模块名称与项目名称保持一致，便于识别
module QingxunScript
end
# frozen_string_literal: true

# 页面控制器（开源版）
#
# 只保留开源版需要的帮助类静态页面：help / script_generation_help / guide。
# 线上版的落地页、下载页、条款/隐私、sitemap、仪表板等已随账号与分发体系移除。
class PagesController < ApplicationController
  # 帮助页面
  # GET /help
  def help
    @faqs = [
      { question: '需要注册账号吗？',
        answer: '不需要。开源版没有账号体系，打开即用，所有数据都保存在你自己的部署里。' },
      { question: '大模型 Key 在哪里配置？',
        answer: '在 config/qingxun.yml 里维护（参考 config/qingxun.yml.example）。Key 只从配置文件读取，不会写入数据库、也不会出现在日志里。' },
      { question: '设备密码会上传吗？',
        answer: '不会。设备 IP、账号、密码只保存在本机数据库中，并以加密形式存储。' },
      { question: '脚本在哪里执行？',
        answer: '脚本先在内置的模拟设备里空跑验证并给出评估结论；确认无误后即可对真实设备执行。' },
      { question: '支持哪些设备？',
        answer: '只要能用 SSH 或 Telnet 敲命令、有回显的设备都支持。型号在「设备型号」里维护，脚本按型号匹配。' },
      { question: '大模型调用怎么计费？',
        answer: '使用你自己配置的 API Key，费用由你的大模型服务商收取，本项目不代收任何费用。' }
    ]
  end

  # 脚本生成帮助页面
  # GET /script_generation_help
  def script_generation_help
    # 帮助页面，内容全在视图里
  end

  # 脚本开发全流程：从手工日志到调试完成的完整闭环
  # GET /guide
  def guide
    # 内容全在视图里，无需实例变量
  end
end

# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# 隐性知识（BYOK 改造相关）：
#   已存在的 :token / :_key 是「部分匹配」，所以 api_token、llm_api_key 会被自动过滤；
#   但 client_code 不含任何既有模式，若不显式加入，识别码会被原样写进请求日志与
#   api_usage_logs.request_params —— 识别码是 bearer 凭据，泄露即可冒用客户身份。
#
# 隐性知识（设备回显 / 需求文本相关）：
#   :log 是部分匹配，一次覆盖 log、log_ref、sandbox_debug_log 这几类专业内容参数；
#   :requirement 覆盖需求与改进要求文本（可能引用设备回显里的网段、口令）；
#   :checkpoints 是逐条检查点结论，里面含设备回显里取出的实际值（端口名、版本号）。
#   这些是**客户的设备输出**，不是平台的调试信息：生产 log_level=info，Rails 会把
#   Parameters:{...} 原文打到 STDOUT（容器日志与日志采集都会留一份）。加这几条之前，
#   /scripts/draft_requirement（手工粘贴的终端日志）就是这么漏出去的；
#   实测还发现 checkpoints 会连同端口名一起写进 api_usage_logs.request_params。
#   过滤掉是"不记录"承诺的第一层；API 侧还有一层显式 except
#   （见 app/controllers/api/v1/base_controller.rb 的 filter_sensitive_params）。
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  :client_code, :llm_api_key, :api_key, :log, :requirement, :checkpoints
]

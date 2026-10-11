# frozen_string_literal: true

# 客户端执行日志的**一次性投递箱**（不是日志存储表）。
#
# 业务逻辑：
#   客户端的「查看脚本日志」弹窗里点「云端改进」后，日志与用户要求要先一步到云端，
#   用户才能在云端脚本生成页里看到它们、点「确定开始修改」让 AI 改进主线描述。两个页面
#   不同源（客户端在本机、服务端在别处），浏览器存储无法跨源交接；
#   而跨站 POST 到云端不带 session cookie（Rails 默认 SameSite=Lax），页面会以匿名身份
#   渲染，既绑不了客户身份也保存不了结果。所以只能：客户端用 API 上传（JWT 认证）→ 拿到
#   一个短令牌 → 用**顶层 GET 导航**打开页面（顶层 GET 会带 Lax cookie，页面才认得出人）。
#
# 隐性知识：
#   1. 这是转交，不是留存：页面读到即 `delete`，`expires_at` 只作兜底（默认 10 分钟），
#      每次上传顺手清过期行。产品口径是"仅用于改进主线描述，不记录"。
#   2. 只存**令牌摘要**（SHA256），明文令牌只出现在回给客户端的 URL 里 —— 库被翻到也拿不到
#      能打开页面的东西。
#   3. log / requirement / error / checkpoints 是**客户的设备输出与需求文本**，列里存的是
#      密文（密钥由 secret_key_base 派生，见模型），所以库转储或备份不会泄露设备回显。
#   4. 不要把它写进 command_mappings / script_versions / api_usage_logs：那些是"脚本的
#      长期资产"，写进去就成了留存，与本表的存在意义相反。
class CreateScriptLogHandoffs < ActiveRecord::Migration[7.1]
  def change
    create_table :script_log_handoffs do |t|
      t.string :token_digest, null: false
      t.bigint :user_id, null: false
      # 目标脚本：客户端只知道云端脚本 id，服务端映射成 script_uid 后存这里。
      # 允许为空 —— 本地自建、或云端已删除的脚本映射不到，此时页面只带日志进入。
      t.string :script_uid
      t.string :script_name
      t.string :task_name
      t.string :execution_id
      t.string :script_status
      t.datetime :captured_at
      t.datetime :expires_at, null: false

      # 以下几列都是密文（MessageEncryptor），checkpoints 是 JSON 字符串再加密
      t.text :log
      t.text :requirement
      t.text :checkpoints
      t.text :error

      t.timestamps
    end

    add_index :script_log_handoffs, :token_digest, unique: true
    # 过期清理与上传时顺手删都用它
    add_index :script_log_handoffs, :expires_at
    add_index :script_log_handoffs, :user_id
  end
end

# frozen_string_literal: true

# 给用户补一个「注册 IP」字段，供管理端用户列表展示。
#
# 业务逻辑：
#   此前只记了 last_login_ip（每次登录都覆盖），看不到"这个客户最初是从哪台机器来的"。
#   这里新增 registration_ip，并在**首次登记**时写入：
#     - 免注册流程：/onboarding/enter 建号时写入（见 User.register_anonymous_client!）
#     - 邮箱账号 / 更老的账号：首次登录时若为空则补写（见 ApplicationController#login_user）
#
# 隐性知识：
#   1. 历史数据只能**尽力回填**：表里原本没有这个信息，借 api_usage_logs（客户端调用日志，
#      记了 ip_address）取每个用户最早一条的 IP 当作注册来源 —— 没调用过接口的账号仍是空，
#      列表里显示「—」。这不是精确的"注册时刻 IP"，但比空字段有用，且不会误导为精确值
#      （列名与页面提示都写成"注册/首次来源 IP"）。
#   2. 只加列不加索引：管理端是全表列表，不做按 IP 检索。
class AddRegistrationIpToUsers < ActiveRecord::Migration[7.1]
  def up
    add_column :users, :registration_ip, :string

    # 尽力回填：每个用户最早一次客户端调用的来源 IP
    execute <<~SQL
      UPDATE users u
         SET registration_ip = src.ip_address
        FROM (
          SELECT DISTINCT ON (user_id) user_id, ip_address
            FROM api_usage_logs
           WHERE user_id IS NOT NULL
             AND ip_address IS NOT NULL
             AND ip_address <> ''
           ORDER BY user_id, created_at ASC
        ) src
       WHERE src.user_id = u.id
         AND (u.registration_ip IS NULL OR u.registration_ip = '')
    SQL
  end

  def down
    remove_column :users, :registration_ip
  end
end

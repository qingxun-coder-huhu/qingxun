# frozen_string_literal: true

# 外部等待期间不占用数据库连接
#
# 业务逻辑：
#   调用外部服务（上游模型、邮件 API）的这段时间里，本线程不做任何数据库操作。但 Rails 的
#   数据库连接是**按线程持有到请求结束**的（请求收尾时由 executor 统一归还），于是"能同时
#   跑几个生成"实际被 config/database.yml 的 pool 卡住，而不是 Puma 线程数。
#
# 隐性知识（实测踩过）：
#   1. pool 只有 5 个连接（RAILS_MAX_THREADS 未设置时的默认值），而一次生成要等约 40 秒
#      （上限 LlmRequestService::DEFAULT_TIMEOUT = 300 秒）。5 个生成在飞就把池占满，
#      第 6 个线程在 checkout 上等 5 秒（checkout_timeout 默认值）后抛
#      ActiveRecord::ConnectionTimeoutError —— 用户看到的是 500，而不是慢慢排队。
#      更糟的是 application_controller#current_user 每个请求开头都要查 User，
#      所以池满了受影响的远不止 AI 请求。
#   2. 归还之后不需要手动借回：本线程下一次访问数据库时 Rails 会透明地重新 checkout。
#   3. **事务里绝不能归还**：连接带着未提交的事务回到池子，会被别的线程借走（或者本线程
#      再借到另一条连接，事务就此断开）。当前所有调用链（各 AI Service / 控制器 / job）
#      都没有事务包裹 LLM 调用，这里仍显式挡一道，让将来把生成放进事务的人不会踩到。
module ExternalWait
  module_function

  # 在块内等待外部服务，期间不占用数据库连接
  def without_db_connection
    release_db_connection
    yield
  end

  # 把当前线程持有的连接还回池子；没有持有、或在事务中，则什么都不做
  def release_db_connection
    pool = ActiveRecord::Base.connection_pool
    connection = pool.active_connection?
    return if connection.nil? || connection.transaction_open?

    pool.release_connection
  end
end

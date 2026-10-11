# frozen_string_literal: true

# net-ssh-telnet 发送路径补丁：write 之后把数据真正推出内核。
#
# 背景（读源码确认，net-ssh-telnet 0.3.1 + net-ssh 7.3.0）：
#   gem 的 `write`（net/ssh/telnet.rb:403-409）只做两件事 —— `@channel.send_data`
#   （把字节放进 **channel 级**缓冲）与一次 `_process_ssh`（`connection.process(0)`）。
#   整个 gem 里没有任何 flush。
#
#   而 net-ssh 这一次 `process(0)` 只是「至多一次机会性 flush」：`enqueue_pending_output`
#   把字节从 channel 缓冲搬进 socket 的 BufferedIo 缓冲后，只有当 `IO.select(..., 0)`
#   那一刻恰好报告可写，才对它调一次 `send_pending`；`send_pending` 只做一次非阻塞
#   `send`、可能只发一部分、且**不循环**；缓冲没有上限，超限也不会自动写出。
#
#   更麻烦的是 `waitfor`：它进循环后第一步是 `IO::select(sock, ..., time_out)` —— 先等满
#   整个超时，才轮到 `_process_ssh` 推数据。于是那次机会性 flush 只要没成，命令就还压在
#   缓冲里，客户端白等一个超时后抛 `Net::ReadTimeout` —— 症状与"设备不回显"完全一样，
#   排查时极容易误判。
#
#   telnet 路径（Net::Telnet）没有这个问题：它用 `wait_writable` + `syswrite` 循环直写，
#   并设了 `@sock.sync = true`。所以本补丁只针对 `Net::SSH::Telnet`。
#
# 为什么在客户端打补丁、而不是改 gem：
#   gem 树（release/qingxun_docker/data/ruby/3.0.0 与 release/qingxun_windows/…/3.2.0）
#   是不入库的外部产物，直接改会随 gem 树重建而丢失；补丁放在仓库里才有版本控制。
#
# 为什么打 `write` 而不是在每个调用点加一次 flush：
#   客户端的写点有五处（login 的用户名/密码、cmd 的 enable 密码、cli 的命令/分页空格/
#   sudo 密码），它们都在 gem 内部经 `print` → `write` 落地。打 `write` 一处即全覆盖。
module NetSshTelnetFlush
  # 默认排空超时（秒）。命令都很小，正常情况下第一轮就空了；这个值只是兜底，
  # 避免"对端不读"时把发送挂死。
  DEFAULT_FLUSH_TIMEOUT = 5

  # 两轮 _process_ssh 之间等待 socket 可写的时间；用带超时的 select 避免忙等。
  SELECT_INTERVAL = 0.05

  # 覆写 write：保持原行为，再把两级缓冲推出去。
  def write(string)
    result = super
    begin
      flush
    rescue NoMethodError, NameError => e
      # gem 内部结构变了（例如升级 net-ssh）：退化成 gem 原行为 —— 排空失败绝不能
      # 让命令发不出去。注意只吞这两类"结构不对"的异常：flush 自己因超时抛出的
      # RuntimeError 要照常冒出去（那条带 pending/window 的诊断才是排查的关键）。
      NetSshTelnetFlush.note_degraded(e)
    end
    result
  end

  # 排空 channel 级与 socket 级两级缓冲。
  #
  # 完成条件是**两级都空**：`Channel#send_data` 写的是 channel 级缓冲，只有
  # `enqueue_pending_output`（在 `_process_ssh` 里）才会按远端 window 把它搬进 socket
  # 缓冲；只看 `socket.pending_write?` 会漏掉"远端窗口用尽、数据还留在 channel 里"。
  #
  # 隐性知识：不要用 `BufferedIo#wait_for_pending_sends` —— 它内部的 `IO.select` 没有
  # 超时，对端不读时会无限阻塞。这里自己带 deadline，超时抛出带诊断的异常。
  def flush(timeout = DEFAULT_FLUSH_TIMEOUT)
    sock = @ssh.transport.socket
    deadline = Time.now + timeout

    loop do
      _process_ssh                      # 驱动一次事件循环：channel 缓冲 -> socket 缓冲 -> 内核
      break if @channel.output.empty? && !sock.pending_write?
      break if sock.closed?             # 连接已断，后面由 waitfor 报错，不在这里抛新异常

      if Time.now > deadline
        raise "flush timeout: pending=#{@channel.output.length}, " \
              "window=#{@channel.remote_window_size}"
      end

      # 等 socket 可写。用 select 而不是固定 sleep：socket 不可写时它会一直等到就绪，
      # 可写时立刻返回（正常路径这一轮就把数据发出去了，不会在这里停留）。
      IO.select(nil, [sock], nil, SELECT_INTERVAL)

      # socket 没东西可发、而数据还卡在 channel 缓冲里（远端 window 未更新，只能等对端
      # 回窗口更新）时，上面的 select 会立刻返回，于是每轮几乎不花时间 —— 补一个短睡，
      # 否则就成了热循环。
      sleep SELECT_INTERVAL if !sock.pending_write? && !@channel.output.empty?
    end
  end

  class << self
    # 补丁依赖 gem 的内部结构，缺任何一项都不装（宁可退回原行为，也不要变成
    # 静默的 NoMethodError）。返回缺失清单，空数组表示齐备。
    def missing_prerequisites(klass)
      missing = []
      missing << :write unless klass.method_defined?(:write)
      missing << :channel unless klass.method_defined?(:channel)
      missing << :_process_ssh unless klass.private_method_defined?(:_process_ssh)
      missing
    end

    # 装上补丁。返回是否装上；装不上时打一条日志说明原因。
    def install!(klass = nil, logger: nil)
      klass ||= (defined?(Net::SSH::Telnet) ? Net::SSH::Telnet : nil)
      unless klass
        log(logger, 'Net::SSH::Telnet 未定义，跳过发送缓冲补丁')
        return false
      end

      missing = missing_prerequisites(klass)
      unless missing.empty?
        log(logger, "跳过发送缓冲补丁：#{klass} 缺少 #{missing.join(', ')}")
        return false
      end

      klass.prepend(self)
      true
    end

    # 运行期降级提示：只打一次，避免每次写命令都刷日志。
    def note_degraded(error)
      return if @degraded

      @degraded = true
      log(nil, "发送缓冲补丁已降级（不再排空，退回 gem 原行为）: #{error.class}: #{error.message}")
    end

    private

    def log(logger, message)
      if logger
        logger.call(message)
      elsif defined?(LogService) && LogService.respond_to?(:warn)
        LogService.warn("[NetSshTelnetFlush] #{message}")
      else
        warn("[NetSshTelnetFlush] #{message}")
      end
    end
  end
end

NetSshTelnetFlush.install!

require 'net/telnet'
require 'net/ssh'
require 'net/ssh/telnet'
require 'timeout'

# SSH 发送缓冲补丁：net-ssh-telnet 的 write 只把数据放进缓冲，一次 process(0) 不保证发出，
# 而 waitfor 进来会先等满整个超时才推数据 —— 结果是"命令还压在缓冲里却报超时"。
# 补丁给 write 加上带 deadline 的排空；放在这里（而不是改 gem）是因为 gem 树是不入库的
# 外部产物，改动会随重建丢失。详见 lib/net_ssh_telnet_flush.rb 的说明。
require_relative 'net_ssh_telnet_flush'

# TelnetDevice 类用于管理通过 Telnet 连接的 CLI 设备（如网络交换机、路由器等）。
# 它封装了 Net::Telnet 客户端，提供了登录、执行命令等高级功能，并处理了设备类型、
# 特权模式等网络设备特有的交互逻辑。
#
# 业务逻辑背景：
# 1. 网络设备通常通过 Telnet 提供命令行接口（CLI）。
# 2. 登录流程：先输入用户名，然后密码，接着可能需要进行特权模式切换（例如 Cisco 的 enable）。
# 3. 特权模式命令因设备厂商而异（Cisco: "enable", Huawei: "super", Juniper: "configure"）。
# 4. 执行命令时需要等待设备返回提示符（prompt），提示符通常以 #、>、$ 等字符结尾。
# 5. 超时和匹配模式是确保命令执行可靠性的关键。
#
# 隐性知识：
# - 如果未提供特权模式命令（enable_command），则不会尝试进入特权模式。
# - 匹配模式（match）是一个正则表达式，用于检测命令输出的结束。
# - 默认匹配模式为 /[$%#>]\s*$/，匹配常见的提示符字符。
# - 登录后，如果设置了 enable_command 和 enable_password，会自动尝试进入特权模式。
class TelnetDevice
  # 默认 Telnet 端口
  DEFAULT_PORT = 23
  DEFAULT_SSH_PORT = 22
  # 默认命令执行超时（秒）
  DEFAULT_TIMEOUT = 30
  # 默认提示符匹配正则表达式
  DEFAULT_MATCH = /[$%#>]\s*$/
  # 超时错误里附带的回显尾部行数。
  # 一条命令可能吐几千行，全量塞进异常会把日志淹掉；只留尾巴够定位就行。
  TIMEOUT_TAIL_LINES = 10
  # cli 单条命令的**总体**时间上限（秒）。
  #
  # 隐性知识：`timeout` 是"每次 waitfor 一次"的 —— 每来一个 `--More--` 就回一个空格，
  # 然后超时重新开始数。于是"输出一直有、只是永远不结束"的命令（设备刷屏、分页器往复、
  # 或者干脆是 `tail -f` 之类）光靠它拦不住：30 秒一页、页页都有，循环可以永远转下去。
  # 这里给一个总量上限兜底。
  #
  # 为什么不设"长度上限"：大输出的命令（整份配置 dump）是正当场景，按行/字节截断会让脚本
  # 拿到半截回显、解析出错误结果 —— 那比慢更糟。内存风险交给这个时间上限兜（再加上分页
  # 协议本身是 RTT 驱动的，速度有天然上限）。
  CLI_MAX_DURATION = 30 * 60
  # cli 单条命令输出量的上限（字节）。
  #
  # 隐性知识：这是**中止**（命令判失败），不是截断 —— 截断会让脚本拿着半截回显去解析，
  # 得到看似成功实则错误的结果，比失败更糟（整份配置 dump 是正当场景，正是要完整拿到）。
  #
  # 64MB 对 CLI 输出来说是"不可能合法"的量级（一份超大配置也就几百 KB），走到这里基本可以
  # 判定是设备在无节制刷屏（或分页器往复），同时也是防 OOM 的兜底 —— 时间上限管不住
  # "不分页、一口吐几十 MB" 的情况。按 chunk 在读取过程中检查，不是等一页收完再查。
  CLI_MAX_BYTES = 64 * 1024 * 1024
  # 报错展示"最后几行"用的**滚动缓冲**上限（字节）。
  #
  # 隐性知识：不能为了报错而把整段输出留一份、或事后再拼一次 `full_output + received` ——
  # 输出可能到 64MB 量级，报错路径上再做一次复制/扫描纯属浪费（而且恰好在内存最紧张的
  # 时刻）。这里只保留最后 TAIL_BUFFER_BYTES 字节，行数另用计数器累加。
  TAIL_BUFFER_BYTES = 8 * 1024
  # SSH 会话申请的伪终端尺寸。
  #
  # 隐性知识（实测踩过）：像 psql 这种"按屏幕高度决定要不要走分页器"的程序，在尺寸偏小
  # （或拿不到尺寸）的 pty 里会把输出交给 less，而无人值守会话里没人按键 —— 客户端只能等到
  # 超时，报错尾巴上能看到 `(END)`（`docker exec -it … psql -c "\l"` 就是这么挂的）。
  #
  # 实测（指定尺寸的 pty，容器内 `stty size` 确认尺寸确实转发进去了）：
  #   pty 50x200 → `docker exec -it … psql -c "\l"` 干净返回，不起分页器
  #   尺寸缺失/偏小 → 起 less，停在 `(END)`
  # 给一个明显大于常见输出的尺寸，一屏装得下就不分页了；真的超过一屏时仍有下面
  # less_end_pattern 的兜底应答。
  PTY_CHARS_WIDE = 200
  PTY_CHARS_HIGH = 50
  # ANSI 转义序列：CSI（颜色、光标移动）、OSC（窗口标题）以及 \e7/\e8 之类的双字符序列。
  # 上游用的是 strings-ansi gem，为了不给部署包增加依赖，这里用正则自己实现。
  ANSI_ESCAPE_SEQUENCE = /\e\[[0-9;?]*[a-zA-Z]|\e\][^\a]*(?:\a|\e\\)|\e[@-Z\\-_]/

  attr_reader :login_steps

  # 测试设备连接（类方法）
  #
  # 参数：
  #   device: 设备对象（必须响应 ip_address, port, connection_type 等属性）
  #   timeout_seconds: 超时时间（秒），默认 10
  #
  # 返回：
  #   包含 status、protocol、message、login_steps 的哈希
  def self.test_conn(device, timeout_seconds = 600)
    protocol = (device.connection_type || 'telnet').to_s.downcase
    telnet_device = new(
      host: device.ip_address,
      port: device.port,
      connection_type: protocol,
      username: device.username,
      password: device.decrypt_password,
      enable_command: device.enable_command,
      enable_password: device.decrypt_enable_password,
      root_password: device.respond_to?(:decrypt_root_password) ? device.decrypt_root_password : nil
    )
    begin
      Timeout.timeout(timeout_seconds) do
        telnet_device.login
      end
      { status: 'online', protocol: protocol, message: "#{protocol} 登录成功", login_steps: telnet_device.login_steps }
    rescue Timeout::Error => e
      { status: 'timeout', protocol: protocol, message: '连接超时', login_steps: telnet_device.login_steps }
    rescue Errno::ECONNREFUSED => e
      { status: 'refused', protocol: protocol, message: '连接被拒绝', login_steps: telnet_device.login_steps }
    rescue Errno::EHOSTUNREACH => e
      { status: 'unreachable', protocol: protocol, message: '主机不可达', login_steps: telnet_device.login_steps }
    rescue => e
      { status: 'error', protocol: protocol, message: e.message, login_steps: telnet_device.login_steps }
    ensure
      telnet_device.close
    end
  end

  # 初始化一个新的 TelnetDevice 实例。
  #
  # 参数：
  #   host: 设备 IP 地址或主机名
  #   port: 端口，默认 Telnet 为 23，SSH 为 22
  #   connection_type: 连接类型 'telnet' 或 'ssh'，默认 'telnet'
  #   username: 登录用户名
  #   password: 登录密码
  #   enable_command: 进入特权模式的命令（如 "enable"），可选
  #   enable_password: 特权模式密码，可选
  #
  # 示例：
  #   # Telnet 连接
  #   dev = TelnetDevice.new(
  #     host: '192.168.1.1',
  #     username: 'admin',
  #     password: 'secret'
  #   )
  #
  #   # SSH 连接
  #   dev = TelnetDevice.new(
  #     host: '192.168.1.1',
  #     connection_type: 'ssh',
  #     username: 'admin',
  #     password: 'secret'
  #   )
  def initialize(host:, port: nil, connection_type: 'telnet', username:, password:,
                  enable_command: nil, enable_password: nil, root_password: nil)
    # 初始化参数

    @host = host
    @connection_type = connection_type.to_s.downcase
    @port = port || (@connection_type == 'ssh' ? DEFAULT_SSH_PORT : DEFAULT_PORT)
    @username = username
    @password = password
    @enable_command = enable_command
    @enable_password = enable_password
    @root_password = root_password
    @login_steps = []
    @connection = nil
  end

  # 建立连接并执行登录流程。
  #
  # 业务逻辑：
  # 1. 根据 connection_type 选择 Telnet 或 SSH 连接
  # 2. Telnet: 等待登录提示，发送用户名/密码
  # 3. SSH: 通过 Net::SSH 完成认证，等待提示符
  # 4. 如果设置了 enable_command，尝试进入特权模式
  # 5. 登录成功后，连接进入"已登录"状态
  #
  # 返回值：self，支持链式调用。
  def login
    add_login_step('开始登录流程', {connection_type: @connection_type, host: @host, port: @port})
    if @connection_type == 'ssh'
      login_ssh
    else
      login_telnet
    end

    # 如果设置了特权模式命令，则尝试进入特权模式
    if @enable_command
      enter_enable_mode
    end

    self
  end

  # 关闭连接。
  def close
    @connection&.close
  rescue => e
    nil
  ensure
    @connection = nil
  end

  # 进入特权模式
  def enter_enable_mode
    # 如果特权模式命令为空或仅包含空白字符，则跳过
    return if @enable_command.to_s.strip.empty?
    add_login_step('尝试进入特权模式', {enable_command: @enable_command})

    response = @connection.cmd('String' => @enable_command, 'Match' => Regexp.union(/[Pp]assword:/, DEFAULT_MATCH))
    add_login_step('特权模式命令响应', {response: response})
    
    if response =~ /[Pp]assword:/
      add_login_step('需要特权密码')
      raise '需要特权密码但未提供' if @enable_password.to_s.strip.empty?
      enable_response = @connection.cmd('String' => @enable_password, 'Match' => DEFAULT_MATCH)
      add_login_step('已发送特权密码')
      add_login_step('进入特权模式成功', {response: enable_response})
    else
      add_login_step('进入特权模式成功', {response: response})
    end
  end

  # 在设备上执行 CLI 命令。
  #
  # 参数：
  #   command: 要执行的命令字符串
  #   timeout: **单次等待回显**的超时时间（秒），可选，默认 DEFAULT_TIMEOUT
  #   match: 用于检测命令结束的正则表达式，可选，默认 DEFAULT_MATCH
  #   max_duration: 整条命令的**总体**时间上限（秒），可选，默认 CLI_MAX_DURATION。
  #                 分页（每来一个 --More-- 就重新计时）绕不过它，见 CLI_MAX_DURATION 的说明
  #   max_bytes: 整条命令的输出量上限（字节），可选，默认 CLI_MAX_BYTES。超了命令判失败
  #              （**不是截断**），见 CLI_MAX_BYTES 的说明
  #
  # 返回值：清洗后的命令输出（去掉分页提示、控制字符、ANSI 序列和命令回显）
  def cli(command, timeout: DEFAULT_TIMEOUT, match: DEFAULT_MATCH,
          max_duration: CLI_MAX_DURATION, max_bytes: CLI_MAX_BYTES)
    raise '未连接。请先调用 login 方法。' unless @connection

    deadline = Time.now + max_duration
    pages = 0

    # 分页提示：Cisco 风格 --More--，Huawei 风格 ---- More ----
    more_pattern = /--More--|-{2,}\s*More\s*-{2,}/i
    # less 停在文件末尾的提示符，形如 \e[7m(END)\e[27m\e[K（反显 + 清行）。
    #
    # 隐性知识：`psql -c "\l"`、`systemctl status` 这类命令在有 pty 的会话里会走 less，
    # 而无人值守时没人按键 —— 实测就是这么超时的（报错尾部能看到 (END)）。
    # 匹配要求整行只有 (END)（允许前后带 ANSI 序列），避免把正文里偶然出现的 "(END)" 当成
    # 提示符：误判会往设备上多发一条 `q` 命令。
    less_end_pattern = /(?:\e\[[0-9;]*[A-Za-z])*[ \t]*\(END\)[ \t]*(?:\e\[[0-9;]*[A-Za-z])*[ \t]*$/
    # sudo 密码提示，例如: [sudo] password for you:
    sudo_password_pattern = /\[sudo\] password for .+:/i

    full_output = ''
    # 报错要展示"最后几行"，但**不为此留一份完整输出**：滚动缓冲只保留最后
    # TAIL_BUFFER_BYTES 字节。行数/字节数用计数器累加，报错时不再扫描或复制整段输出 ——
    # 原来在超时路径上拼 `full_output + received`，输出到 64MB 时等于在最缺内存的时刻
    # 又复制一份。
    #
    # 行数精确：换行符个数是拼接不变量，末尾再加"结尾那半行"（ends_with_newline）。
    tail_buffer = +''
    total_bytes = 0
    newline_count = 0
    ends_with_newline = true
    sudo_answered = false

    # 先把命令发下去，再等输出。下面的循环只负责读，不发命令。
    @connection.puts(command)

    loop do
      pages += 1
      received_lines = lines_received(newline_count, total_bytes, ends_with_newline)
      # 总体上限：分页会不断重置 timeout，只有这里能拦住"一直有输出、永远不结束"的命令。
      remaining = deadline - Time.now
      if remaining <= 0
        raise "命令超过总时长上限（#{max_duration}s）：#{command}\n" \
              "已翻 #{pages} 页、收到 #{received_lines} 行。\n" \
              "#{tail_excerpt(tail_buffer) || '（没有收到任何回显）'}"
      end

      patterns = [more_pattern, less_end_pattern, match]
      # 应答过一次之后就不再匹配 sudo 提示，否则命令会在提示符处提前结束，
      # 拿不到提权之后真正的输出。
      patterns << sudo_password_pattern unless sudo_answered

      # 必须用 block 收集回显：waitfor 一旦超时就不返回任何东西，只有 block 能看到
      # "等待期间收到的数据" —— 而报错信息里要带的正是这一段（见 timeout_error_message）。
      #
      # 单页等待不超过"剩余总预算"：否则最后那一页还能把总量撑出 max_duration 一个整 timeout。
      per_page_timeout = [timeout, remaining].min
      received = +''
      begin
        @connection.waitfor('Match' => Regexp.union(patterns), 'Timeout' => per_page_timeout) do |data|
          next unless data

          received << data
          total_bytes += data.bytesize
          newline_count += data.count("\n")
          ends_with_newline = data.end_with?("\n")
          append_tail(tail_buffer, data)

          # 输出量上限：按 chunk 查，不等这一页收完 —— 否则设备一口吐几十 MB 时，
          # 内存已经吃满才报错（时间上限管不住这种"不分页、猛吐"的情况）。
          next unless total_bytes > max_bytes

          limit = "#{max_bytes} 字节#{max_bytes >= 1_048_576 ? " = #{max_bytes / 1_048_576}MB" : ''}"
          raise "命令输出超过上限（#{limit}）：#{command}\n" \
                "已翻 #{pages} 页、收到 #{lines_received(newline_count, total_bytes, ends_with_newline)} 行 / " \
                "#{total_bytes} 字节。\n" \
                "#{tail_excerpt(tail_buffer) || '（没有收到任何回显）'}"
        end
      rescue Net::ReadTimeout => e
        # 保留原异常类与堆栈：上层是按 Net::ReadTimeout 捕获的，堆栈里 waitfor 那几帧
        # 也是排查时最熟悉的定位点。
        #
        # 若这次超时其实是"总预算用完"，说清楚是预算问题，别让人以为是设备不回话。
        # 计数器在 block 里随 chunk 更新，所以这里已经包含本次等待收到的数据。
        received_lines = lines_received(newline_count, total_bytes, ends_with_newline)
        message = if Time.now >= deadline
                    "命令超过总时长上限（#{max_duration}s）：#{command}\n" \
                    "已翻 #{pages} 页、收到 #{received_lines} 行。\n" \
                    "#{tail_excerpt(tail_buffer) || '（没有收到任何回显）'}"
                  else
                    timeout_error_message(command, timeout, tail_buffer, received_lines)
                  end
        raise Net::ReadTimeout, message, e.backtrace
      end
      full_output << received

      if received =~ more_pattern
        @connection.puts(' ')
      elsif received =~ less_end_pattern
        # less 停在末尾等按键：按 q 退出，让命令回到提示符，再继续读。
        #
        # 注意这只能救"已经翻到末尾"的情况：输出超过一屏时 less 停在中间是**没有标记**的，
        # 检测不到，只能靠超时 + 错误信息里的尾部回显定位。所以素材里最好直接用非交互命令
        # （`psql -Atc "…"` 或 `-P pager=off`），这一句只是兜底。
        @connection.puts('q')

      elsif !sudo_answered && received =~ sudo_password_pattern
        if @root_password.to_s.empty?
          raise '需要 root 密码但未提供（设备提示 sudo 密码）'
        end
        add_login_step('检测到 sudo 密码提示，自动输入 root 密码')
        sudo_answered = true
        @connection.puts(@root_password)
      else
        break
      end
    end

    clean_cli_output(full_output, command)
  end

  private

  # 超时时的错误信息：带上"已经收到多少行、最后几行是什么"。
  #
  # 隐性知识（实测踩过）：命令超时最常见的原因不是网络断了，而是这条命令在无人值守的
  # 会话里根本跑不完 —— 典型是交互式命令在等按键（例如 `docker exec -it … psql -c "\l"`
  # 里的分页器），设备其实一直在吐数据，只是永远等不到提示符。原来只报一句
  # Net::ReadTimeout，拿着日志只能猜卡在哪；把尾部回显带出来，一眼就能看出是分页、
  # 是密码提示、还是真的没反应。
  #
  # 只带尾部 TIMEOUT_TAIL_LINES 行：一条命令可能吐几千行，全量塞进异常会把日志淹掉。
  #
  # tail_buffer 是 cli 里维护的**有界**滚动缓冲（见 TAIL_BUFFER_BYTES），lines 是同一处
  # 累加出来的行数 —— 这里不再接收整段输出，避免报错路径上复制/扫描 64MB 级的内容。
  def timeout_error_message(command, timeout, tail_buffer, lines)
    header = "等待命令回显超时（#{timeout}s）：#{command}"
    excerpt = tail_excerpt(tail_buffer)
    return "#{header}\n超时前没有收到任何回显。" if excerpt.nil?

    "#{header}\n超时前共收到 #{lines} 行，#{excerpt}"
  end

  # 已收到的行数：换行符个数 + 结尾那半行（空输出算 0 行）。
  #
  # 逐 chunk 累加而不是事后扫描整段输出：输出到上限时是 64MB 量级，报错路径上不该再为它
  # 做一次 O(n) 扫描（而且这样算出来是精确值，不用"约"）。
  def lines_received(newline_count, total_bytes, ends_with_newline)
    return 0 if total_bytes.zero?

    newline_count + (ends_with_newline ? 0 : 1)
  end

  # 往"最后几行"滚动缓冲里追加一个 chunk，原地裁到 TAIL_BUFFER_BYTES 以内。
  #
  # 这个缓冲是**唯一**为报错留存输出内容的地方，必须恒定有界 —— 之前是攒满整段输出、
  # 报错时再拼一次，输出到上限（64MB）时白复制一份。按字节裁可能切断多字节字符，
  # 展示前由 tail_excerpt 用 scrub 收尾。
  def append_tail(tail_buffer, data)
    tail_buffer << data
    excess = tail_buffer.bytesize - TAIL_BUFFER_BYTES
    tail_buffer.replace(tail_buffer.byteslice(excess, TAIL_BUFFER_BYTES)) if excess.positive?
    tail_buffer
  end

  # 尾部回显片段："最后 N 行：…"，供各类超时/超量报错复用；没有任何回显时返回 nil。
  #
  # 入参应是有界的滚动缓冲（cli 的 tail_buffer）；这里仍然只取最后若干字节再切行 ——
  # 不 split 整段输入，也不为它分配"每行一个字符串"的数组。
  def tail_excerpt(output, bytes: TAIL_BUFFER_BYTES)
    text = output.to_s
    return nil if text.empty?

    tail_text = text.bytesize > bytes ? text.byteslice(-bytes, bytes) : text
    tail_text = tail_text.scrub('?') # 按字节切可能切断多字节字符
    tail = tail_text.split("\n").last(TIMEOUT_TAIL_LINES)
    "最后 #{tail.size} 行：\n" + tail.map { |line| "    #{line}" }.join("\n")
  end

  # 添加登录步骤
  def add_login_step(step, details = nil)
    @login_steps << { 
      timestamp: Time.now.strftime('%Y-%m-%d %H:%M:%S.%L'),
      step: step,
      details: details 
    }
  end

  # Telnet 登录流程
  def login_telnet
    # Telnet 登录流程开始
    @connection = Net::Telnet.new(
      'Host' => @host,
      'Port' => @port,
      'Timeout' => DEFAULT_TIMEOUT,
      'Prompt' => DEFAULT_MATCH
    )
    # Telnet connection created
    add_login_step('开始Telnet连接', {host: @host, port: @port})

    # 等待用户名提示符（Username: 或 login:）
    username_prompt = @connection.waitfor('Match' => /[Uu]sername:|[Ll]ogin:/)
    add_login_step('收到用户名提示符', {prompt: username_prompt})
    @connection.puts(@username)
    add_login_step('已发送用户名', {username: @username})
    # 等待密码提示符（Password:）
    password_prompt = @connection.waitfor('Match' => /[Pp]assword:/)
    add_login_step('收到密码提示符', {prompt: password_prompt})
    @connection.puts(@password)
    add_login_step('已发送密码')

    # 检查登录是否成功
    error_pattern = /error|login incorrect|authentication failed|invalid|denied|fail/i
    combined_pattern = Regexp.union(DEFAULT_MATCH, error_pattern)
    response = @connection.waitfor('Match' => combined_pattern)
    if response =~ error_pattern
      @connection.close rescue nil
      @connection = nil
      add_login_step('登录失败', {error: response})
      raise "Telnet 登录失败: #{response}"
    end
    add_login_step('登录成功', {response: response})
    # 登录完成
  end

  # SSH 登录流程
  def login_ssh
    # SSH 登录流程开始
    add_login_step('开始SSH连接', {host: @host, port: @port, username: @username})

    # Net::SSH::Telnet 接受 Port 参数，并且也会传递给 Net::SSH.start
    #
    # PTYOptions 会被 gem 原样透传给 Net::SSH 的 request_pty（net-ssh 只认
    # term/chars_wide/chars_high/pixels_*/modes 这几个键，传别的会 ArgumentError），
    # 用来避免 psql/less 这类程序因为没有屏幕尺寸而强行分页 —— 见 PTY_CHARS_HIGH 的说明。
    @connection = Net::SSH::Telnet.new(
      "Host" => @host,
      "Port" => @port,
      "Username" => @username,
      "Password" => @password,
      "Prompt" => DEFAULT_MATCH,
      "Waittime" => 0.2,
      "PTY" => true,
      "PTYOptions" => { chars_wide: PTY_CHARS_WIDE, chars_high: PTY_CHARS_HIGH }
    )
    # Net::SSH::Telnet 连接创建完成
    add_login_step('SSH登录成功')
  rescue => e
    @connection = nil
    add_login_step('SSH登录失败', {error: e.message})
    raise "SSH 登录失败: #{e.message}"
  end

  

  # 清洗 CLI 原始输出：分页提示、控制字符、转义序列、命令回显依次处理。
  def clean_cli_output(output, command)
    result = clean_more_prompt(output)
    result = apply_control_characters(result)
    result = remove_save_restore_cursor(result)
    result = remove_window_title_sequence(result)
    result = strip_ansi_sequences(result)
    result = remove_command_echo(result, command)
    result.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
  end

  # 清理分页提示，只保留文档内容
  #
  # 提示可能带颜色（\e[7m--More--\e[0m），也可能不带；Huawei 设备用的是 ---- More ----。
  # 提示后面通常还跟着一串空格或退格，用来把提示本身擦掉，所以一并吃掉。
  def clean_more_prompt(output)
    output.gsub(/(?:\e\[[0-9;]*m)?(?:--More--|-{2,}\s*More\s*-{2,})[^\r\n]*(?:\r?\n)?/i, '')
  end

  # 按照语义处理控制字符（\b、\r、\n）。
  #
  # 设备回显里 \r 只回到行首而不换行，直接当普通字符处理会让同一行内容重复叠加，
  # 所以要按终端语义重建每一行。
  def apply_control_characters(output)
    lines = ['']
    line_idx = 0
    col = 0

    output.each_char do |ch|
      case ch
      when "\b"  # 退格：删除前一个字符
        if col > 0
          lines[line_idx] = lines[line_idx][0...col - 1] + lines[line_idx][col..].to_s
          col -= 1
        end
      when "\r"  # 回车：光标回到行首
        col = 0
      when "\n"  # 换行：开始新行
        line_idx += 1
        lines[line_idx] = ''
        col = 0
      else       # 普通字符：覆盖或追加
        if col < lines[line_idx].length
          lines[line_idx][col] = ch
        else
          lines[line_idx] << ch
        end
        col += 1
      end
    end

    lines.join("\n")
  end

  # 移除命令回显，确保返回值第一行不包含命令本身
  def remove_command_echo(output, command)
    return output if output.nil? || output.empty? || command.nil? || command.empty?

    lines = output.lines.map(&:chomp)

    # 情况1：第一行就是命令本身，整行移除
    if lines.first == command
      lines.shift
      return lines.join("\n")
    end

    # 情况2：第一行以命令开头，后面跟着空白或分隔符
    if !lines.empty? && lines[0].start_with?(command) && lines[0][command.length] =~ /\s/
      remaining = lines[0][command.length..].to_s.strip
      if remaining.empty?
        lines.shift
      else
        lines[0] = remaining
      end
      return lines.join("\n")
    end

    # 情况3：命令回显跨行（命令后面直接跟了换行）
    if output.start_with?(command) && ["\n", "\r", ' '].include?(output[command.length])
      return output[command.length..].to_s.lstrip
    end

    output
  end

  # 删除 \e7（保存光标位置）和 \e8（恢复光标位置）之间的所有内容
  def remove_save_restore_cursor(output)
    result = +''
    i = 0
    while i < output.length
      if output[i] == "\e" && i + 1 < output.length && output[i + 1] == '7'
        j = i + 2
        found_e8 = false
        while j < output.length
          if output[j] == "\e" && j + 1 < output.length && output[j + 1] == '8'
            i = j + 2
            found_e8 = true
            break
          end
          j += 1
        end
        # 没有配对的 \e8 时，只跳过 \e7 标记本身
        i += 2 unless found_e8
      else
        result << output[i]
        i += 1
      end
    end
    result
  end

  # 删除窗口标题序列 (\e]0;...\a)
  def remove_window_title_sequence(output)
    output.gsub(/\e\]0;.*?\a/, '')
  end

  # 去掉剩余的 ANSI 转义序列（颜色、光标移动等）。
  def strip_ansi_sequences(output)
    output.gsub(ANSI_ESCAPE_SEQUENCE, '')
  end
end

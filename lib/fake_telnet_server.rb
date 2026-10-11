# frozen_string_literal: true

# 轻量级 Fake Telnet 服务器，用于测试 TelnetDevice 类及其他 Telnet 客户端。
# 该服务器模拟网络设备的基本 CLI 交互，包括登录、特权模式切换和命令执行。
# 设计目标：
# 1. 纯 Ruby 实现，不依赖外部 gem（除标准库外）。
# 2. 忽略 Telnet 协议选项（IAC），仅处理文本交互。
# 3. 支持多连接，每个连接在独立线程中处理。
# 4. 可配置的认证凭据、命令映射和提示符。
# 5. 易于集成到 RSpec 测试中，也可作为独立脚本运行。
#
# 业务逻辑背景：
# - 网络设备（如 Cisco 交换机）通过 Telnet 提供 CLI。
# - 典型登录流程：设备发送 "Username:" 提示，用户输入用户名；然后发送 "Password:" 提示，用户输入密码。
# - 登录成功后，设备发送命令提示符（如 ">" 或 "#"），等待用户输入命令。
# - 特权模式切换：用户输入 "enable" 命令，设备可能要求输入特权密码（enable password）。
# - 命令执行：用户输入命令后，设备返回相应输出，并再次发送提示符。
#
# 隐性知识：
# - 某些设备在密码提示下不回显字符，但本服务器仅模拟文本流，不关心回显。
# - 提示符通常以空格结尾（如 "Switch#"），但实际匹配时客户端使用正则表达式。
# - 命令输出通常以换行符结尾，且末尾包含提示符（客户端需要匹配提示符以确定命令结束）。
# - 本服务器在每条命令输出后自动附加提示符，以模拟真实设备行为。
# - 忽略 Telnet IAC 命令：客户端（Net::Telnet）可能会发送 IAC 协商请求，若服务器不响应，可能导致客户端挂起。
#   因此，本服务器会简单过滤掉收到的 IAC 序列（以 0xFF 开头的字节）。
#
# 使用示例：
#   server = FakeTelnetServer.new(port: 2323, username: 'admin', password: 'secret')
#   server.add_command('show version', "Cisco IOS Software, Version 15.2(4)M7\n")
#   server.start
#   # 在另一个终端中使用 telnet 或 TelnetDevice 连接 localhost:2323 进行测试
#   server.stop
#
require 'socket'
require 'thread'

class FakeTelnetServer
  # 默认配置
  DEFAULT_PORT = 2323
  DEFAULT_HOST = 'localhost'
  DEFAULT_USERNAME = 'admin'
  DEFAULT_PASSWORD = 'password'
  DEFAULT_ENABLE_PASSWORD = 'enable'
  DEFAULT_LOGIN_PROMPT = 'Username: '
  DEFAULT_PASSWORD_PROMPT = 'Password: '
  DEFAULT_COMMAND_PROMPT = 'Switch> '
  DEFAULT_PRIVILEGED_PROMPT = 'Switch# '

  # 初始化 Fake Telnet 服务器。
  #
  # 参数：
  #   host: 绑定主机地址（默认 'localhost'）
  #   port: 监听端口（默认 2323）
  #   username: 登录用户名（可选，默认 'admin'）
  #   password: 登录密码（可选，默认 'password'）
  #   enable_password: 特权模式密码（可选，默认 'enable'）
  #   login_prompt: 登录提示符（可选）
  #   password_prompt: 密码提示符（可选）
  #   command_prompt: 普通模式提示符（可选）
  #   privileged_prompt: 特权模式提示符（可选）
  #
  # 业务逻辑：
  #   保存配置，初始化命令映射和状态。
  #
  # 隐性知识：
  #   如果未提供 enable_password，则特权模式切换不需要密码（某些设备允许空密码）。
  #   提示符字符串通常以空格结尾，以便与客户端正则表达式匹配。
  def initialize(host: DEFAULT_HOST, port: DEFAULT_PORT,
                 username: DEFAULT_USERNAME, password: DEFAULT_PASSWORD,
                 enable_password: DEFAULT_ENABLE_PASSWORD,
                 login_prompt: DEFAULT_LOGIN_PROMPT,
                 password_prompt: DEFAULT_PASSWORD_PROMPT,
                 command_prompt: DEFAULT_COMMAND_PROMPT,
                 privileged_prompt: DEFAULT_PRIVILEGED_PROMPT)
    @host = host
    @port = port
    @username = username
    @password = password
    @enable_password = enable_password
    @login_prompt = login_prompt
    @password_prompt = password_prompt
    @command_prompt = command_prompt
    @privileged_prompt = privileged_prompt

    # 命令映射树的根节点列表。节点结构：
    #   { pattern:, response:, children:, exit_level: }
    # pattern 为命令字符串（精确匹配）或正则表达式；children 非空表示"命中即进入该上下文"。
    # 顶层平铺映射只是"没有 children 的根节点"，因此旧的 add_command 用法保持不变。
    @commands = []
    # 默认命令：帮助、退出、enable、show version。
    # 隐性知识：原先这行被注释掉，导致直接使用 FakeTelnetServer 时没有任何默认命令，
    # 落到兜底分支返回 "not recognized"（debug_session_spec / fake_telnet_server_spec 因此失败）。
    # FakeTelnetServerManager 会先 clear_command 再灌入自定义映射，所以恢复默认命令不影响任务调试。
    add_default_commands

    # 服务器状态
    @server = nil
    @thread = nil
    @clients = []
    @mutex = Mutex.new
  end

  # 添加自定义命令。
  #
  # 参数：
  #   pattern: 字符串（精确匹配）或正则表达式（匹配命令前缀）
  #   response: 字符串、Proc 或 Method 对象。如果是可调用对象，将传入匹配的捕获组（如果有）。
  #
  # 业务逻辑：
  #   当客户端发送命令时，服务器按添加顺序查找匹配的模式，并返回相应的响应。
  #   如果 pattern 是正则表达式，则匹配的捕获组将作为参数传递给可调用对象。
  #
  # 隐性知识：
  #   命令匹配优先级：先添加的优先匹配。建议将精确匹配命令放在前面，通用正则放在后面。
  #   响应字符串可以包含换行符，服务器会自动在响应后附加当前提示符。
  def add_command(pattern, response)
    @commands << { pattern: pattern, response: response, children: [], exit_level: nil }
  end

  # 按嵌套树批量添加命令（供命令映射 JSON 使用）。
  #
  # 参数：
  #   nodes: 节点数组，每个节点支持 symbol 或 string 键：
  #     command:    命令字符串（精确匹配）或正则，必填
  #     response:   响应字符串 / Proc（空字符串是合法回显）
  #     children:   子节点数组，非空表示命中该命令后进入下一层上下文
  #     exit_level: 整数，命中后向根方向退几层；1=上一层，0=回根；缺省则不改层级
  #
  # 隐性知识：
  #   children / exit_level 是**仅模拟服务器使用**的导航元数据：真机不认识它们，
  #   生成的脚本也绝不会下发它们——它们只存在于命令映射里，用来驱动本模拟器的上下文切换。
  #   这里刻意不提供"每层自定义提示符"的能力：提示符因设备而异，让映射写死它会污染生成的脚本。
  def add_command_tree(nodes)
    Array(nodes).each { |node| @commands << build_node(node) }
  end

  # 移除已添加的命令。
  def clear_command
    @commands = []
  end

  

  # 启动服务器。
  #
  # 业务逻辑：
  #   创建 TCPServer 并绑定到指定主机和端口。
  #   启动一个后台线程，循环接受客户端连接，并为每个连接创建新线程处理。
  #
  # 隐性知识：
  #   服务器线程会捕获异常并打印错误信息，但不会终止（除非严重错误）。
  #   调用 start 后，服务器将一直运行直到调用 stop。
  #   如果 port 为 0，系统会自动分配随机端口，需要从 server 中获取实际端口。
  def start
    @mutex.synchronize do
      return if @thread && @thread.alive?
      @server = TCPServer.new(@host, @port)
      # 如果使用随机端口（port 为 0），获取实际分配的端口
      @port = @server.addr[1] if @port == 0
      @thread = Thread.new { run }
    end
    puts "FakeTelnetServer 启动在 #{@host}:#{@port}"
  end

  # 停止服务器。
  #
  # 业务逻辑：
  #   关闭监听套接字，中断 accept 阻塞。
  #   等待服务器线程结束，并关闭所有客户端连接。
  #
  # 隐性知识：
  #   关闭客户端连接时，会发送 TCP FIN 包，客户端会收到 EOF。
  #   停止后，可以再次调用 start 重新启动。
  def stop
    @mutex.synchronize do
      return unless @thread && @thread.alive?
      @server.close rescue nil
      @thread.kill
      @thread.join
      @clients.each(&:close)
      @clients.clear
      @server = nil
      @thread = nil
    end
    puts "FakeTelnetServer 已停止"
  end

  # 返回服务器是否正在运行。
  def running?
    @thread&.alive? || false
  end

  private

  # 获取当前线程的连接状态哈希。
  def connection_state
    Thread.current[:fake_telnet_state] ||= {
      logged_in: false,
      privileged: false,
      expect_username: true,
      expect_password: false,
      expect_enable_password: false,
      buffer: String.new,
      context_stack: []
    }
  end

  # 当前连接的上下文栈，栈顶是当前所在的上下文节点，空栈表示在根上下文。
  #
  # 隐性知识：
  #   上下文是 per-connection 的（存在线程局部状态里），命令树本身是全局共享的。
  #   这里对缺失键做懒初始化，兼容直接构造 state 的调用方（例如既有测试）。
  def context_stack
    state = connection_state
    state[:context_stack] ||= []
  end

  # 把映射节点（symbol / string 键均可）转换为内部节点结构。
  #
  # 隐性知识：
  #   这里给每个节点记下 parent，是为了在"进入某层"时能还原出它完整的祖先链
  #   （见 context_path_of）。父子互相引用只存在于内存，命令映射 JSON 里没有这一层。
  def build_node(raw, parent = nil)
    node = {
      pattern: field(raw, :command) || field(raw, :pattern),
      response: field(raw, :response),
      children: [],
      exit_level: field(raw, :exit_level),
      parent: parent
    }
    node[:children] = Array(field(raw, :children)).map { |child| build_node(child, node) }
    node
  end

  # 兼容 symbol / string 两种键的节点字段读取。
  def field(hash, key)
    return nil unless hash.is_a?(Hash)

    hash.key?(key) ? hash[key] : hash[key.to_s]
  end

  # 默认命令：帮助、退出、enable 等。
  def add_default_commands
    add_command(/^help$/i, "Available commands: help, exit, enable, show version")
    add_command(/^exit$/i, proc { |_| close_connection })
    add_command(/^enable$/i, proc do |_|
      state = connection_state
      if @enable_password.nil? || @enable_password.empty?
        state[:privileged] = true
        "Entering privileged mode.\n"
      else
        state[:expect_enable_password] = true
        "Password: "
      end
    end)
    add_command(/^show version$/i, "Cisco IOS Software, Version 15.2(4)M7\nCopyright (c) 1986-2019 by Cisco Systems, Inc.\nCompiled Wed 15-May-19 07:15 by prod_rel_team")
  end

  # 服务器主循环：接受连接并为每个连接创建处理线程。
  def run
    loop do
      client = @server.accept
      @mutex.synchronize { @clients << client }
      Thread.new { handle_client(client) }
    end
  rescue IOError, Errno::EBADF
    # 服务器套接字被关闭，正常退出
  rescue => e
    puts "FakeTelnetServer 异常: #{e.class}: #{e.message}"
    puts e.backtrace.join("\n")
  end

  # 处理单个客户端连接。
  #
  # 业务逻辑：
  #   1. 发送登录提示，等待用户名。
  #   2. 验证用户名后发送密码提示，等待密码。
  #   3. 验证密码后发送命令提示符，进入命令循环。
  #   4. 接收客户端命令，查找匹配并发送响应。
  #   5. 支持特权模式切换（enable）。
  #
  # 隐性知识：
  #   客户端可能发送 Telnet IAC 命令（字节 0xFF）。本服务器会过滤掉这些字节。
  #   命令以换行符（"\n" 或 "\r\n"）分隔。
  #   服务器在发送任何输出后都会附加当前提示符（普通或特权）。
  #   如果客户端发送空行，服务器仅重新发送提示符。
  def handle_client(client)
    # 每个连接的状态
    Thread.current[:fake_telnet_state] = {
      logged_in: false,
      privileged: false,
      expect_username: true,
      expect_password: false,
      expect_enable_password: false,
      buffer: String.new,
      context_stack: []
    }

    send_data(client, @login_prompt)
    loop do
      data = client.readpartial(1024)
      # 按行记录接收到的数据，便于调试
      data.lines.each_with_index do |line, idx|
        p "recv_data[line #{idx+1}]: #{line.chomp.inspect}"
      end
      # 处理 Telnet IAC 协商并过滤掉 IAC 序列
      filtered = handle_iac_negotiation(client, data)
      process_data(client, filtered)
    end
  rescue EOFError, IOError, Errno::ECONNRESET
    # 客户端断开连接
  ensure
    client.close rescue nil
    @mutex.synchronize { @clients.delete(client) }
  end

  # 处理 Telnet IAC 协商并过滤掉 IAC 序列。
  # 该方法会解析接收到的数据中的 IAC 命令（0xFF），并发送适当的拒绝响应，
  # 同时返回过滤掉所有 IAC 序列后的文本数据。
  #
  # 参数：
  #   client: 客户端套接字对象，用于发送响应
  #   data: 原始字节字符串
  # 返回：
  #   过滤后的字符串（移除了所有 IAC 序列，包括子协商）
  #
  # 隐性知识：
  #   Telnet 协议中，客户端发送 IAC 命令来协商选项（如回显、二进制模式等）。
  #   服务器若忽略这些命令，客户端可能会等待响应而超时。
  #   本服务器对常见的 DO/WILL 命令回应 WONT/DONT，以拒绝所有选项协商。
  #   子协商（IAC SB ... IAC SE）被完全跳过。
  #   文字 IAC（0xFF 0xFF）被保留为单个 0xFF。
  def handle_iac_negotiation(client, data)
    return data unless data.bytes.include?(0xFF)

    bytes = data.bytes
    result = []
    i = 0
    while i < bytes.length
      if bytes[i] == 0xFF  # IAC
        if i + 1 < bytes.length
          cmd = bytes[i + 1]
          case cmd
          when 251, 252, 253, 254  # WILL, WONT, DO, DONT
            # 发送拒绝响应：对于 DO (253) 回应 WONT (252)，对于 WILL (251) 回应 DONT (254)
            # 注意：选项字节是下一个字节（i+2），但我们不需要读取它
            response_cmd = (cmd == 253 || cmd == 254) ? 252 : 254
            response = [0xFF, response_cmd, bytes[i + 2]].pack('C*')
            client.write(response) rescue nil
            i += 3  # 跳过 IAC, command, option
            next
          when 250  # SB (子协商开始)
            # 跳过整个子协商，直到遇到 IAC SE (0xFF 240)
            j = i + 2
            while j + 1 < bytes.length && !(bytes[j] == 0xFF && bytes[j + 1] == 240)
              j += 1
            end
            if j + 1 < bytes.length
              i = j + 2  # 跳过 IAC SE
            else
              # 未找到结束标记，跳过剩余所有字节
              i = bytes.length
            end
            next
          when 255  # 文字 IAC (0xFF 0xFF)
            # 保留一个 0xFF
            result << 0xFF
            i += 2
            next
          else
            # 未知命令，跳过两个字节（IAC + cmd）
            i += 2
            next
          end
        else
          # 单独的 0xFF，忽略
          i += 1
        end
      else
        result << bytes[i]
        i += 1
      end
    end
    result.pack('C*').force_encoding('UTF-8')
  end

  # 过滤 Telnet IAC 序列。
  #
  # 参数：
  #   data: 原始字节字符串
  # 返回：
  #   过滤后的字符串（移除以 0xFF 开头的三个字节序列）
  #
  # 隐性知识：
  #   Telnet IAC 序列格式：0xFF（IAC）后跟命令字节和选项字节。
  #   本服务器简单地删除所有 0xFF 及其后两个字节，因为客户端（Net::Telnet）通常会发送 DO/DONT 协商。
  #   更严谨的实现应解析并响应协商，但鉴于需求为“不需要 Telnet 协议选项”，此简化方法可行。
  def filter_iac(data)
    return data unless data.bytes.include?(0xFF)
    bytes = data.bytes
    result = []
    i = 0
    while i < bytes.length
      if bytes[i] == 0xFF && i + 2 < bytes.length
        # 跳过三个字节：IAC + command + option
        i += 3
      else
        result << bytes[i]
        i += 1
      end
    end
    result.pack('C*').force_encoding('UTF-8')
  end

  # 处理接收到的数据。
  def process_data(client, data)
    state = connection_state
    state[:buffer] << data
    # 按行分割（支持 \n 或 \r\n）
    while line = state[:buffer].slice!(/^.*?[\r\n]+/)
      line = line.chomp
      handle_line(client, line)
    end
  end

  # 处理单行输入。
  def handle_line(client, line)
    state = connection_state
    if state[:expect_enable_password]
      handle_enable_password(client, line)
    elsif state[:expect_username]
      handle_username(client, line)
    elsif state[:expect_password]
      handle_password(client, line)
    elsif state[:logged_in]
      handle_command(client, line)
    else
      # 未登录且不在预期状态，忽略
    end
  end

  # 处理用户名输入。
  def handle_username(client, line)
    state = connection_state
    if line == @username
      state[:expect_username] = false
      state[:expect_password] = true
      send_data(client, @password_prompt)
    else
      send_data(client, "Invalid username.\n#{@login_prompt}")
    end
  end

  # 处理密码输入。
  def handle_password(client, line)
    state = connection_state
    if line == @password
      state[:expect_password] = false
      state[:logged_in] = true
      send_data(client, current_prompt(state))
    else
      send_data(client, "Invalid password.\n#{@login_prompt}")
      state[:expect_username] = true
      state[:expect_password] = false
    end
  end

  # 处理特权模式密码输入。
  def handle_enable_password(client, line)
    state = connection_state
    if line == @enable_password
      state[:privileged] = true
      state[:expect_enable_password] = false
      send_data(client, "Entering privileged mode.\n")
      send_data(client, @privileged_prompt)
    else
      send_data(client, "Bad secrets.\n")
      state[:expect_enable_password] = false
      send_data(client, current_prompt(state))
    end
  end

  # 处理已登录状态下的命令。
  #
  # 业务逻辑：
  #   先按"就近优先、逐级向上兜底到根"的规则在命令树里找节点：从当前上下文的 children
  #   起，逐级向上到根节点列表，同级按声明顺序取第一个命中。命中后若节点带 children，
  #   压栈进入该上下文；若声明了 exit_level，按声明向根方向弹栈。
  #
  # 隐性知识：
  #   "逐级向上兜底到根"意味着 enable、show version 这类全局命令只写在根节点即可，
  #   在任何上下文里都能命中——这也是"未声明退出层级时默认回到根"的实现基础。
  def handle_command(client, line)
    # 空命令（只敲一个回车）在真实设备上会把提示符原样返回，而不是"没有响应"。
    # 早先这里直接 return、什么都不发，客户端等不到提示符就会一直等到超时——
    # 需求里"下发空命令 → 收到空字符串（含提示符）"这一步因此挂起。
    if line.empty?
      send_prompt(client)
      return
    end

    state = connection_state
    node, match = find_command_node(line)

    if node.nil?
      response = "Command '#{line}' not recognized.\n"
    else
      response = node[:response]
      # 如果 response 是可调用对象，传递正则捕获组；无捕获组时按无参调用
      response = match ? response.call(*match.captures) : response.call if response.respond_to?(:call)
      apply_context_navigation(node) unless response == :close_connection
    end

    # 如果 response 是 :close_connection 特殊符号，关闭连接
    if response == :close_connection
      client.close
      puts "close client"
      return
    end

    # 发送命令响应
    response_str = response.to_s
    prompt = current_prompt(state)

    # 移除响应末尾可能已经存在的提示符（避免重复）
    if response_str.end_with?(prompt + "\n")
      response_str = response_str[0...-(prompt.length + 1)]
      puts "[FakeTelnetServer] 移除响应末尾的提示符+换行符"
    elsif response_str.end_with?(prompt)
      response_str = response_str[0...-prompt.length]
      puts "[FakeTelnetServer] 移除响应末尾的提示符"
    end

    # 报文与提示符必须在**同一次写入**中发送。
    #
    # 隐性知识（这里出过真问题）：客户端（TelnetDevice）用 /[$#>]\s*$/ 这类正则判断命令
    # 是否结束。若报文先单独发一次、提示符再单独发一次，客户端可能在只收到报文时就匹配成功
    # ——只要报文里某一行以 > / # / $ 结尾（例如 "Enter selection>"、以 # 结尾的告警行），
    # 输出就会提前返回，真正的提示符残留在客户端缓冲区；下一条命令会先读到这个残留提示符，
    # 于是输出与命令错位、后续状态全乱。合成一次写可消除这个竞态窗口。
    unless state[:expect_password] || state[:expect_enable_password]
      send_data(client, response_str + "\n" + prompt)
    else
      send_data(client, response_str)
    end
  end

  # 在当前上下文中查找命令节点。
  #
  # 返回 [node, match_data]（正则命中时带 MatchData），未命中返回 nil。
  # 查找范围：当前上下文节点的 children → 逐级父节点的 children → 根节点列表。
  def find_command_node(line)
    search_lists = context_stack.reverse.map { |node| node[:children] }
    search_lists << @commands

    search_lists.each do |nodes|
      # 反向遍历：**后注册者优先**。默认命令在 initialize 时先注册，
      # 用户/映射后注册的同名命令应当覆盖默认命令（debug_session / 调试映射都依赖这一点）。
      Array(nodes).reverse_each do |node|
        pattern = node[:pattern]
        if pattern.is_a?(String) && pattern == line
          return [node, nil]
        elsif pattern.is_a?(Regexp) && pattern =~ line
          return [node, Regexp.last_match]
        end
      end
    end
    nil
  end

  # 根据命中的节点更新上下文栈。
  #
  # 隐性知识：
  #   节点带 children 表示"这条命令是进入下一层的入口"，命中即进入；进入时把栈**替换成
  #   该节点完整的祖先链**，而不是简单压栈。这样"从 1 号单板直接切到 2 号单板"（两者是
  #   兄弟层）会正确落到 2 号单板，而不会把 2 号嵌进 1 号里；重复进入同一层也不会重复压栈。
  #   exit_level 是退出命令的声明：1=回上一层，0=回根；它与 children 互斥（有 children 时忽略）。
  def apply_context_navigation(node)
    if Array(node[:children]).any?
      context_stack.replace(context_path_of(node))
    elsif !node[:exit_level].nil?
      pop_context(node[:exit_level])
    end
  end

  # 沿 parent 链回溯出"根 → 该节点"的完整路径。
  def context_path_of(node)
    chain = []
    current = node
    while current
      chain.unshift(current)
      current = current[:parent]
    end
    chain
  end

  # 按声明的层级向根方向弹栈：0（或负数）回到根，N 表示退 N 层。
  def pop_context(exit_level)
    stack = context_stack
    level = exit_level.to_i
    if level <= 0
      stack.clear
    else
      level.times { stack.pop }
    end
  end

  # 当前提示符。
  #
  # 隐性知识：
  #   提示符**不随上下文变化**，也不会由命令映射指定。同一个脚本要跑在不同设备上，各家提示符
  #   都不一样（`Switch>`、`slot1>`、`(config)#` …），一旦让映射写死提示符，生成的脚本就可能
  #   跟着依赖某个具体提示符，换设备即废。所以这里始终用服务器自身的提示符；
  #   上下文层级只体现在「命令在哪个 children 里生效」，与提示符无关。
  def current_prompt(state = connection_state)
    state[:privileged] ? @privileged_prompt : @command_prompt
  end

  # 发送数据到客户端，确保编码为 ASCII‑8BIT（二进制）以避免编码问题。
  def send_data(client, data)
    # 显示可读格式：将控制字符转换为转义序列
    display_data = data.gsub("\r", "\\r").gsub("\n", "\\n").gsub("\t", "\\t")
    p "send_data[#{display_data}]"
    client.write(data)
  rescue IOError, Errno::EPIPE
    # 客户端已断开，忽略
  end

  # 发送当前提示符。
  def send_prompt(client)
    send_data(client, "\n" + current_prompt)
  end

  # 特殊响应：关闭连接。
  def close_connection
    :close_connection
  end
end
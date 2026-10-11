# frozen_string_literal: true

require 'fileutils'
require 'json'

# LLM 交互的文件日志：按「会话」分目录存储
#
# 业务逻辑：
#   一次用户请求（user_request_id）算作一次会话，它触发的多次 LLM 调用
#   （生成脚本、沙盒评估、失败重试、最终建议……）全部写进同一个文件夹。
#   目录名用**日期时间**，便于按时间浏览排查：
#
#     logs/llm_sessions/20260912-110233123/
#       _session.json                       # 本会话的元信息（含 request_id，供反查）
#       20260912T110233456-001-ScriptGenerationService-generate_script.json
#       20260912T110240789-002-ScriptEvaluationService-evaluate.json
#       ...
#
# 隐性知识：
#   1. 本服务**取代了原先的 llm_interactions 数据库表**（该表已停写）。改为文件的好处是
#      可直接翻阅，且不必把大段设备回显塞进数据库。
#   2. 目录名刻意**不用 request_id**（UUID 无法一眼看出时间）；但管理页需要按 request_id
#      反查，所以每个会话目录里放一份 `_session.json` 记录 request_id，`read` 靠它定位。
#   3. **绝不写入 Key**：只记录 messages 与响应，headers / api_key 一律不落盘。
#      这是 BYOK 的核心承诺，改动这段代码时必须保持。
#   4. 会话目录名在同一次请求内必须稳定（多次调用落同一个文件夹）：用线程局部按
#      request_id 缓存，首次调用时生成，后续复用。
#   5. 拿不到 request_id 的调用（后台任务等）每次调用各建一个日期时间目录，
#      而不是抛错或丢弃——否则排查时会发现"明明调了却没有记录"。
#   6. **写日志失败绝不影响主流程**：所有磁盘操作都包在 rescue 里，只记 Rails.logger。
class LlmSessionLogger
  # 会话元信息文件名；以 _ 开头，读取交互时会被排除
  SESSION_META_FILENAME = '_session.json'

  # 日志根目录。默认 logs/llm_sessions；测试里会改写到 tmp，避免污染真实日志。
  class << self
    attr_writer :root

    def root
      @root ||= Rails.root.join('logs', 'llm_sessions')
    end
  end

  # 读出的一条交互记录。
  # 接口刻意对齐原先的 LlmInteraction（request_messages / response_content / success? …），
  # 这样管理页视图几乎不用改。
  Entry = Struct.new(
    :interaction_id, :session_id, :service_name, :step_name, :model,
    :success, :created_at, :response_time_ms,
    :request_data, :response_data, :error_message,
    keyword_init: true
  ) do
    def success?
      !!success
    end

    def request_messages
      data = request_data || {}
      data['messages'] || data[:messages] || []
    end

    def response_content
      if response_data.is_a?(Hash)
        response_data.dig('choices', 0, 'message', 'content') ||
          response_data[:content] || response_data.to_s
      else
        response_data.to_s
      end
    end
  end

  class << self
    # 开始记录一次交互；返回写入句柄，调用方在成功/失败时回填结果
    def start(request_context, service_name:, step_name:, model:, messages:)
      Session.new(request_context, service_name, step_name, model, messages)
    end

    # 读取某个会话（按 request_id 反查目录）下的全部交互，按时间升序
    def read(request_id)
      dir = session_dir_for(request_id)
      return [] unless dir

      interaction_files(dir).filter_map { |path| parse_entry(path) }
    rescue StandardError => e
      Rails.logger.error "[LlmSessionLogger] 读取会话失败 #{request_id}: #{e.class}: #{e.message}"
      []
    end

    # 某个会话的计数（管理页列表用，避免视图里调用三次 read）
    def counts(request_id)
      entries = read(request_id)
      {
        total: entries.size,
        successful: entries.count(&:success?),
        failed: entries.count { |e| !e.success? }
      }
    end

    # 按 interaction_id 全局查找
    def find(interaction_id)
      return nil if interaction_id.blank?

      all_interaction_files.sort.each do |path|
        entry = parse_entry(path)
        return entry if entry && entry.interaction_id == interaction_id
      end
      nil
    rescue StandardError => e
      Rails.logger.error "[LlmSessionLogger] 查找交互失败 #{interaction_id}: #{e.class}: #{e.message}"
      nil
    end

    # 遍历所有会话的所有交互（统计用）；since 为时间下限
    def each_entry(since: nil)
      return enum_for(:each_entry, since: since) unless block_given?

      all_interaction_files.sort.each do |path|
        entry = parse_entry(path)
        next unless entry
        next if since && entry.created_at && entry.created_at < since

        yield entry
      end
    rescue StandardError => e
      Rails.logger.error "[LlmSessionLogger] 遍历交互失败: #{e.class}: #{e.message}"
    end

    # 按目录名取会话目录
    def session_dir(folder_name)
      root.join(safe_segment(folder_name))
    end

    # 按 request_id 反查会话目录：优先 _session.json，兼容历史上直接用 request_id 命名的目录
    def session_dir_for(request_id)
      return nil if request_id.blank?

      legacy = root.join(safe_segment(request_id))
      return legacy if Dir.exist?(legacy)

      Dir.glob(File.join(root.to_s, '*', SESSION_META_FILENAME)).sort.each do |meta|
        data = JSON.parse(File.read(meta))
        return Pathname.new(File.dirname(meta)) if data['request_id'] == request_id
      rescue StandardError
        next
      end
      nil
    rescue StandardError => e
      Rails.logger.error "[LlmSessionLogger] 反查会话目录失败 #{request_id}: #{e.class}: #{e.message}"
      nil
    end

    # 全部会话目录名
    def all_session_ids
      return [] unless Dir.exist?(root)

      Dir.children(root).select { |name| File.directory?(File.join(root.to_s, name)) }.sort
    end

    private

    # 一个会话目录下的交互文件（排除 _session.json），按文件名升序
    def interaction_files(dir)
      Dir.glob(File.join(dir.to_s, '*.json'))
         .reject { |path| File.basename(path) == SESSION_META_FILENAME }
         .sort
    end

    def all_interaction_files
      Dir.glob(File.join(root.to_s, '*', '*.json'))
         .reject { |path| File.basename(path) == SESSION_META_FILENAME }
    end

    def parse_entry(path)
      raw = JSON.parse(File.read(path))
      Entry.new(
        interaction_id: raw['interaction_id'],
        session_id: raw['session_id'],
        service_name: raw['service_name'],
        step_name: raw['step_name'],
        model: raw['model'],
        success: raw['success'],
        created_at: parse_time(raw['finished_at'] || raw['started_at']),
        response_time_ms: raw['response_time_ms'],
        request_data: raw['request'],
        response_data: raw['response'],
        error_message: raw['error_message']
      )
    rescue StandardError => e
      Rails.logger.warn "[LlmSessionLogger] 跳过损坏的日志文件 #{path}: #{e.message}"
      nil
    end

    def parse_time(value)
      value && Time.zone.parse(value)
    rescue StandardError
      nil
    end

    # 目录/文件名只允许安全字符，避免异常字符逃出根目录
    def safe_segment(value)
      value.to_s.gsub(/[^0-9A-Za-z._-]/, '_')
    end
  end

  # 一次交互的写入句柄
  #
  # 生命周期：call 开始时 start，成功调 success，失败调 failure；两者都会落一个文件。
  # 失败路径也落盘是刻意的——出问题时最需要看的就是失败那一次。
  class Session
    def initialize(request_context, service_name, step_name, model, messages)
      @context = request_context || {}
      @service_name = service_name
      @step_name = step_name
      @model = model
      @messages = messages
      @started_at = Time.current
      @session_id = resolve_session_id
    end

    def success(response, response_time_ms)
      write(success: true, response: response, response_time_ms: response_time_ms)
    end

    def failure(error_message, response_time_ms = nil)
      write(success: false, error_message: error_message, response_time_ms: response_time_ms)
    end

    private

    # 目录名 = 日期时间。同一次请求内的多次调用必须落同一个目录，
    # 因此按 request_id 缓存在线程局部；没有 request_id 时每次调用各建一个目录。
    def resolve_session_id
      request_id = @context[:request_id]
      if request_id.present?
        cache = (Thread.current[:llm_session_dirs] ||= {})
        cache[request_id] ||= build_session_id
      else
        build_session_id
      end
    end

    def build_session_id
      # 目录名用**服务器本地时间**，便于对照服务器时钟排查（Rails 的 Time.zone 默认是 UTC，
      # 直接用它会让目录名比运维看到的时间差一个时区）。JSON 内的 started_at/finished_at
      # 仍是 UTC ISO8601，保持无歧义。
      candidate = Time.now.strftime('%Y%m%d-%H%M%S%L')
      # 极端情况：两个请求落在同一毫秒。加短后缀避免两个会话混进一个目录。
      if Dir.exist?(LlmSessionLogger.root.join(candidate))
        candidate = "#{candidate}-#{SecureRandom.hex(2)}"
      end
      candidate
    end

    def write(success:, response: nil, error_message: nil, response_time_ms: nil)
      dir = LlmSessionLogger.session_dir(@session_id)
      FileUtils.mkdir_p(dir)
      write_session_meta(dir)

      payload = {
        'interaction_id' => SecureRandom.uuid,
        'session_id' => @session_id,
        'request_id' => @context[:request_id],
        'user_id' => @context[:user_id],
        'request_type' => @context[:request_type],
        'path' => @context[:path],
        'service_name' => @service_name,
        'step_name' => @step_name,
        'model' => @model,
        'started_at' => @started_at.utc.iso8601(3),
        'finished_at' => Time.current.utc.iso8601(3),
        'response_time_ms' => response_time_ms,
        'success' => success,
        'request' => { 'messages' => @messages },
        'response' => response,
        'error_message' => error_message
      }

      final_path = File.join(dir.to_s, filename)
      tmp_path = "#{final_path}.tmp"
      # 先写临时文件再改名：避免读到写了一半的 JSON
      File.write(tmp_path, JSON.pretty_generate(payload))
      File.rename(tmp_path, final_path)

      # 同时写一份带真实换行的可读日志，便于直接看提示词（JSON 里的换行是转义的 \n）
      write_readable(final_path, payload)

      final_path
    rescue StandardError => e
      Rails.logger.error "[LlmSessionLogger] 写入交互日志失败: #{e.class}: #{e.message}"
      nil
    end

    # 写可读日志：把 messages 按角色铺开、保留真实换行，输出到同名 .log 文件。
    # 隐性知识：JSON 是给程序读的（管理页按 *.json 反查），.log 是给人看的；
    # 读取逻辑只 glob *.json，因此 .log 不会被当成一条交互记录。
    def write_readable(json_path, payload)
      log_path = json_path.sub(/\.json\z/, '.log')
      File.write(log_path, render_readable(payload))
    rescue StandardError => e
      Rails.logger.error "[LlmSessionLogger] 写入可读日志失败: #{e.class}: #{e.message}"
    end

    def render_readable(payload)
      sep = '=' * 88
      messages = payload.dig('request', 'messages') || []

      lines = []
      lines << sep
      lines << "#{human_time(payload['started_at'])}  #{payload['service_name']}/#{payload['step_name']}"
      lines << "模型: #{payload['model']}   会话: #{payload['session_id']}   " \
               "成功: #{payload['success']}   耗时: #{payload['response_time_ms']&.round(1)}ms"
      lines << sep

      messages.each_with_index do |msg, idx|
        role = (msg['role'] || msg[:role] || 'unknown').to_s.upcase
        content = msg['content'] || msg[:content]
        lines << ''
        lines << "---------- [#{idx + 1}/#{messages.size}] #{role} ----------"
        lines << content.to_s
      end

      lines << ''
      lines << '---------- 响应 ----------'
      lines << response_text(payload['response'])

      if payload['error_message'].to_s != ''
        lines << ''
        lines << '---------- 错误 ----------'
        lines << payload['error_message'].to_s
      end

      lines << ''
      lines.join("\n")
    end

    # 成功响应优先取正文（模型输出），否则把结构化响应 pretty 出来（本身带换行）
    def response_text(response)
      if response.is_a?(Hash)
        content = response.dig('choices', 0, 'message', 'content') || response['content']
        return content.to_s if content
      end

      JSON.pretty_generate(response)
    rescue StandardError
      response.to_s
    end

    # 日志给人看，用服务器本地时间，和目录命名保持一致
    def human_time(iso)
      return Time.now.strftime('%Y-%m-%d %H:%M:%S') if iso.to_s.empty?

      Time.zone.parse(iso).localtime.strftime('%Y-%m-%d %H:%M:%S')
    rescue StandardError
      iso.to_s
    end

    # 会话元信息：记录 request_id 等，供管理页按 request_id 反查目录。只写一次。
    def write_session_meta(dir)
      meta_path = File.join(dir.to_s, SESSION_META_FILENAME)
      return if File.exist?(meta_path)

      meta = {
        'session_id' => @session_id,
        'request_id' => @context[:request_id],
        'user_id' => @context[:user_id],
        'request_type' => @context[:request_type],
        'path' => @context[:path],
        'started_at' => @started_at.utc.iso8601(3)
      }
      tmp_path = "#{meta_path}.tmp"
      File.write(tmp_path, JSON.pretty_generate(meta))
      File.rename(tmp_path, meta_path)
    rescue StandardError => e
      Rails.logger.error "[LlmSessionLogger] 写入会话元信息失败: #{e.class}: #{e.message}"
    end

    def filename
      stamp = Time.now.strftime('%Y%m%dT%H%M%S%L')
      raw = [stamp, format('%03d', next_sequence), @service_name, @step_name].compact.join('-')
      "#{raw.gsub(/[^0-9A-Za-z._-]/, '_')}.json"
    end

    # 同一会话内的序号：保证同一毫秒内的多次调用也有稳定顺序
    def next_sequence
      store = (Thread.current[:llm_session_seq] ||= {})
      store[@session_id] = store[@session_id].to_i + 1
    end
  end
end

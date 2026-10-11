# frozen_string_literal: true

require 'tempfile'
require_relative 'file_path_utils'
require_relative 'qingxun'

# 脚本执行器（复用本地客户端的 lib/script_executor.rb，做两处适配）
#
# 适配说明（与客户端版的差异，其余逻辑一致）：
#   1. 用本框架的 `Qingxun::Sandbox` 执行，而不是裸 `load` + `script_instance.run(conn)`：
#      危险命令拦截与「下发命令/收到报文」日志由 Sandbox / SandboxConnection 负责，
#      因此不再需要客户端里的 `create_connection_wrapper`。这是"保留沙箱"的选择。
#   2. 自定义集成由框架的 `Qingxun::Integrations::Custom` 按 `script_user` 加载，
#      不再用客户端的 `eval(code)` 方式。
#
# 保留的客户端逻辑：临时文件 + `load` 脚本、`LogBuffer`（实时日志，支持回调）、
# `find_script_class`（QingxunScript/Qingxun/Object 三级查找）、结论四态判定、结果格式化。
class ScriptExecutor
  # on_log: 追加日志时的回调（用于"边执行边落库/展示"）
  def initialize(on_log: nil)
    @on_log = on_log
  end

  # 执行单个脚本
  # @param device [TelnetDevice] 已登录的设备对象
  # @param script_info [Hash] { name:, code:, log_file_path:, user: }
  # @return [Hash] { output:, error:, conclusion:, result:, checkpoints:, script_result: }
  def execute(device, script_info)
    script_name = script_info['name'] || script_info[:name] || 'unknown'
    code = script_info['code'] || script_info[:code]
    log_file_path = script_info['log_file_path'] || script_info[:log_file_path]
    user = script_info['user'] || script_info[:user]
    error = nil
    conclusion = 'success'
    result = nil
    script_instance = nil
    script_error = nil

    log_buffer = LogBuffer.new(log_file_path, on_append: @on_log)

    begin
      if code && !code.empty?
        temp_file = Tempfile.new(['qingxun_script_', '.rb'], FilePathUtils.task_tmp_dir)
        begin
          temp_file.write(code)
          temp_file.close

          log_buffer.append("[信息] 开始执行脚本: #{script_name}\n")
          log_buffer.append("[信息] 加载脚本文件...\n")

          # 复用客户端的加载方式：load（每次都重新加载），而不是 require
          load temp_file.path

          log_buffer.append("[信息] 查找脚本类...\n")
          script_class = find_script_class(code)
          if script_class
            log_buffer.append("[信息] 找到脚本类: #{script_class.name}\n")
            script_instance = script_class.new({}, log_buffer)
            script_instance.script_user = user if user && script_instance.respond_to?(:script_user=)
            script_instance.record_start!

            log_buffer.append("[信息] 调用 run(connection)...\n")
            # 适配点 1：走框架沙箱执行（含危险命令拦截与命令/报文日志）
            sandbox = Qingxun::Sandbox.new(script_instance, device, log_buffer)
            result = sandbox.run
            log_buffer.append("[信息] 脚本执行完成\n")
            log_buffer.append("[结果]\n#{format_script_result(result)}\n") if result
          else
            log_buffer.append("[错误] 无法找到脚本类\n")
            conclusion = 'error' # 脚本压根没执行 —— 执行异常
          end
        ensure
          temp_file.close! if temp_file
        end
      else
        log_buffer.append("[警告] 脚本代码为空\n")
      end

    rescue StandardError => e
      script_error = e
      error = e.message
      conclusion = 'error'
      log_buffer.append("[错误] 脚本执行异常: #{e.message}\n")
      log_buffer.append("[错误] 堆栈跟踪:\n#{e.backtrace.join("\n")}\n")
    ensure
      log_buffer.close
    end

    execution_result = {
      output: log_buffer.content,
      error: error,
      conclusion: conclusion,
      result: result
    }

    if script_instance
      script_result = script_instance.build_script_result(script_error)
      execution_result[:checkpoints] = script_result.checkpoints
      execution_result[:script_result] = script_result.to_h

      # 结论四态：success / partial（部分通过）/ failure（一个都没过）/ error（执行异常）
      case script_result.status
      when 'some_failed'
        passed_count = script_result.checkpoints.count { |cp| cp[:passed] == true }
        conclusion = passed_count.positive? ? 'partial' : 'failure'
      when 'error'
        conclusion = 'error'
      end
      execution_result[:conclusion] = conclusion
    end

    execution_result
  end

  private

  # 格式化脚本结果，生成易读的输出（复用客户端）
  def format_script_result(result)
    return result.inspect unless result.is_a?(Qingxun::ScriptResult)

    output = []
    output << "=" * 60
    output << "脚本执行结果"
    output << "=" * 60
    output << "状态: #{result.success ? '成功' : '失败'}"
    output << "执行结果: #{result.status}"
    output << "错误: #{result.error || '无'}"

    if result.summary.is_a?(Hash)
      passed = result.summary[:passed] || result.summary['passed'] || 0
      failed = result.summary[:failed] || result.summary['failed'] || 0
      total = result.summary[:total] || result.summary['total'] || 0
      output << "检查点统计: 通过 #{passed}/#{total}，失败 #{failed}/#{total}"
    end

    output << "执行时长: #{'%.3f' % result.duration} 秒"
    output << "开始时间: #{result.started_at}"
    output << "结束时间: #{result.finished_at}"

    if result.checkpoints && !result.checkpoints.empty?
      output << ""
      output << "检查点详情:"
      output << "-" * 40
      result.checkpoints.each_with_index do |checkpoint, i|
        status = if checkpoint[:passed] == true
                   '✓ 通过'
                 elsif checkpoint[:passed] == false
                   '✗ 失败'
                 else
                   '? 未完成'
                 end
        output << "#{i + 1}. #{checkpoint[:name]} - #{status}"
        if checkpoint[:value]
          value_str = checkpoint[:value].to_s.gsub(/\r?\n/, ' ')
          value_str = "#{value_str[0..77]}..." if value_str.length > 80
          output << "   值: #{value_str}"
        end
        output << "   命令: #{checkpoint[:command]}" if checkpoint[:command]
        output << "   预期: #{checkpoint[:expected]}" if checkpoint[:expected]
        if checkpoint[:passed] == false
          output << "   原因: #{checkpoint[:reason].to_s.gsub(/\r?\n/, ' ')}" if checkpoint[:reason]
          output << "   建议: #{checkpoint[:suggestion]}" if checkpoint[:suggestion]
        end
        output << "" unless i == result.checkpoints.size - 1
      end
    end

    output << "=" * 60
    output.join("\n")
  end

  # 日志缓冲器（复用客户端）：实时写入文件 + 内存保留完整内容 + 追加回调
  class LogBuffer
    def initialize(log_file_path = nil, on_append: nil)
      @content = +''
      @log_file = nil
      @on_append = on_append
      if log_file_path
        FilePathUtils.ensure_file_dir_exists(log_file_path)
        @log_file = File.open(log_file_path, 'w:utf-8')
      end
    end

    def timestamp_prefix
      Time.now.strftime('%Y-%m-%d %H:%M:%S')
    end

    def append(text)
      chunk = +''
      if text.match?(/\A\[(INFO|ERROR|WARN|DEBUG|命令|输出|信息|错误|警告|结果|提示)\]/)
        lines = text.split("\n")
        first_line = true
        lines.each do |line|
          next if line.empty?

          if first_line
            timed_line = "[#{timestamp_prefix}] #{line}\n"
            @content << timed_line
            chunk << timed_line
            first_line = false
          else
            @content << "#{line}\n"
            chunk << "#{line}\n"
          end
        end
      else
        @content << text
        chunk << text
      end
      @log_file.write(chunk) if @log_file
      @log_file.flush if @log_file
      @on_append&.call(chunk)
    end

    def content
      @content
    end

    def close
      @log_file.close if @log_file
    end

    # 作为脚本的 logger 使用（DeviceScript 的 log_* 方法会调用 logger.info 等）
    def info(msg) = append("[INFO] #{msg}\n")
    def error(msg) = append("[ERROR] #{msg}\n")
    def warn(msg) = append("[WARN] #{msg}\n")
    def debug(msg) = append("[DEBUG] #{msg}\n")
  end

  # 查找脚本类（复用客户端）：从代码解析类名，依次在 QingxunScript / Qingxun / Object 中查找
  def find_script_class(code)
    class_match = code.match(/class\s+(\w+)\s*<\s*Qingxun::DeviceScript/)
    return nil unless class_match

    class_name = class_match[1]
    namespaces = []
    namespaces << QingxunScript if defined?(QingxunScript)
    namespaces << Qingxun
    namespaces << Object

    namespaces.each do |namespace|
      next unless namespace.const_defined?(class_name)

      klass = namespace.const_get(class_name)
      return klass if klass.is_a?(Class) && klass <= Qingxun::DeviceScript
    end
    nil
  end
end

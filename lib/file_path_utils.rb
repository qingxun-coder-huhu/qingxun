# frozen_string_literal: true

# 文件路径工具类
module FilePathUtils
  class << self
    # 清理目录/文件名，剔除非法字符
    # 非法字符: / \ : * ? " < > |
    # IPv6地址的冒号转换为下划线
    #
    # 入参可能是字符串以外的类型（例如云端返回的整数设备 id 会一路传到这里），
    # 名字清理不该因此炸掉，一律先 to_s。
    def sanitize_filename(name)
      text = name.to_s
      return '' if text.empty?

      # 先处理IPv6地址的冒号
      # IPv6地址特征：包含多个冒号，可能有字母数字
      processed = text.gsub(/([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}/) do |ipv6|
        ipv6.gsub(':', '_')
      end
      
      # 剔除其他非法字符
      processed.gsub(%r{[\/\\:*?"<>|]}, '_')
    end

    # 生成任务执行根目录路径
    # logs/任务名称/
    def task_root_dir(task_name, base_logs_dir: './logs')
      task_dir = sanitize_filename(task_name)
      File.join(base_logs_dir, task_dir)
    end

    # 任务临时文件目录
    def task_tmp_dir
      dir = './tmp'
      ensure_dir_exists(dir)
      dir
    end

    # 生成网元日志目录路径
    # logs/任务名称/logs/网元ip/
    def device_log_dir(task_name, device_ip, base_logs_dir: './logs')
      root_dir = task_root_dir(task_name, base_logs_dir: base_logs_dir)
      sanitized_ip = sanitize_filename(device_ip)
      File.join(root_dir, 'logs', sanitized_ip)
    end

    # 生成脚本日志目录路径
    # logs/任务名称/logs/网元ip/脚本名称/
    def script_log_dir(task_name, device_ip, script_name, base_logs_dir: './logs')
      device_dir = device_log_dir(task_name, device_ip, base_logs_dir: base_logs_dir)
      sanitized_script = sanitize_filename(script_name)
      File.join(device_dir, sanitized_script)
    end

    # 生成设备日志文件路径
    # logs/任务名称/logs/网元ip/脚本名称/devlog.txt
    def devlog_file_path(task_name, device_ip, script_name, base_logs_dir: './logs')
      script_dir = script_log_dir(task_name, device_ip, script_name, base_logs_dir: base_logs_dir)
      File.join(script_dir, 'devlog.txt')
    end

    # 生成登录日志文件路径
    # logs/任务名称/logs/网元ip/login_log.txt
    def login_log_file_path(task_name, device_ip, base_logs_dir: './logs')
      device_dir = device_log_dir(task_name, device_ip, base_logs_dir: base_logs_dir)
      File.join(device_dir, 'login_log.txt')
    end

    # 生成任务报告文件路径
    # logs/任务名称/任务报告
    def task_report_file_path(task_name, base_logs_dir: './logs')
      root_dir = task_root_dir(task_name, base_logs_dir: base_logs_dir)
      File.join(root_dir, '任务报告')
    end

    # 生成任务JSON状态文件路径
    # logs/任务名称/任务json状态
    def task_json_status_file_path(task_name, base_logs_dir: './logs')
      root_dir = task_root_dir(task_name, base_logs_dir: base_logs_dir)
      File.join(root_dir, '任务json状态')
    end

    # 确保目录存在
    def ensure_dir_exists(dir_path)
      FileUtils.mkdir_p(dir_path) unless Dir.exist?(dir_path)
    end

    # 确保文件所在目录存在
    def ensure_file_dir_exists(file_path)
      dir_path = File.dirname(file_path)
      ensure_dir_exists(dir_path)
    end

    # 写入JSON状态到文件
    def write_json_status(file_path, data)
      ensure_file_dir_exists(file_path)
      File.write(file_path, JSON.pretty_generate(data))
    end

    # 从文件读取JSON状态
    def read_json_status(file_path)
      return nil unless File.exist?(file_path)
      content = File.read(file_path)
      JSON.parse(content) rescue nil
    end
  end
end

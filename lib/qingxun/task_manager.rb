# frozen_string_literal: true

require 'json'
require 'thread'
require_relative 'device_executor'

# TaskManager 是框架的入口点，负责加载任务定义并协调多设备并行执行。
#
# 业务逻辑背景：
# - 网络运维任务通常涉及批量设备（如全网交换机巡检）。
# - 任务定义以 JSON 形式描述，包含设备列表和要执行的脚本列表。
# - 设备之间相互独立，可以并行执行以提高效率。
# - 任务管理器需要收集每个设备的执行结果，并生成整体报告。
#
# 隐性知识：
# - 任务 JSON 文件必须包含 task_id、devices 和 scripts 字段。
# - 设备并行执行使用 Ruby 线程实现，适合 I/O 密集型操作（网络连接）。
# - 线程数默认无限制（每个设备一个线程），大量设备时需注意系统资源。
# - 任务执行过程中，日志会自动写入按任务 ID 组织的目录中。
# - 任务管理器本身也会记录启动、完成等高级别日志（写入标准输出或单独文件）。
#
module Qingxun
  class TaskManager
    # 执行任务。
    #
    # 参数：
    #   task_file_path: JSON 任务定义文件的路径
    #   options: 可选配置哈希，支持以下键：
    #     - scripts_dir: 脚本目录（默认为 'scripts'）
    #     - logs_dir: 日志根目录（默认为 'logs'）
    #     - max_concurrency: 最大并发设备数（默认为 nil，表示无限制）
    #     - fail_fast: 是否在任一设备失败时立即停止任务（默认为 false）
    #
    # 返回值：
    #   Hash 包含以下键：
    #     - success: 布尔值，表示整个任务是否成功（所有设备成功）
    #     - task_id: 任务标识符
    #     - total_devices: 设备总数
    #     - succeeded_devices: 成功的设备数
    #     - failed_devices: 失败的设备数
    #     - devices: 数组，每个元素是 DeviceExecutor 返回的设备结果哈希
    #     - start_time: 任务开始时间（Time 对象）
    #     - end_time: 任务结束时间（Time 对象）
    #     - elapsed: 总耗时（秒）
    #
    # 抛出：
    #   Errno::ENOENT 如果任务文件不存在。
    #   JSON::ParserError 如果 JSON 格式无效。
    #   KeyError 如果任务缺少必需字段。
    #
    def self.run(task_file_path, options = {})
      start_time = Time.now
      puts "[#{start_time}] 开始执行任务文件: #{task_file_path}"

      # 加载任务定义
      task = load_task(task_file_path)
      task_id = task['task_id']
      devices = task['devices']
      script_names = task['scripts']

      # 应用选项
      scripts_dir = options[:scripts_dir] || 'scripts'
      logs_dir = options[:logs_dir] || 'logs'
      max_concurrency = options[:max_concurrency] || 20
      fail_fast = options[:fail_fast] || false

      # 准备设备执行器
      executors = devices.map do |device_config|
        # 转换键为符号（JSON 解析后键为字符串）
        config = symbolize_keys(device_config)
        DeviceExecutor.new(config, script_names, task_id,
                           scripts_dir: scripts_dir, logs_dir: logs_dir)
      end

      # 并行执行
      device_results = parallel_execute(executors, max_concurrency, fail_fast)

      # 汇总结果
      succeeded = device_results.count { |r| r[:success] }
      failed = device_results.size - succeeded
      overall_success = failed.zero?

      end_time = Time.now
      elapsed = end_time - start_time

      puts "[#{end_time}] 任务完成，成功设备 #{succeeded}/#{devices.size}，总耗时 #{elapsed.round(2)} 秒"

      {
        success: overall_success,
        task_id: task_id,
        total_devices: devices.size,
        succeeded_devices: succeeded,
        failed_devices: failed,
        devices: device_results,
        start_time: start_time,
        end_time: end_time,
        elapsed: elapsed
      }
    end

    private

    # 加载并验证任务 JSON 文件。
    def self.load_task(file_path)
      content = File.read(file_path)
      task = JSON.parse(content)

      # 必需字段检查
      %w[task_id devices scripts].each do |key|
        raise KeyError, "任务定义缺少必需字段: #{key}" unless task.key?(key)
      end

      # 确保 devices 是数组，scripts 是字符串数组
      raise 'devices 必须是一个数组' unless task['devices'].is_a?(Array)
      raise 'scripts 必须是一个字符串数组' unless task['scripts'].is_a?(Array)

      task
    end

    # 将哈希的键从字符串转换为符号（浅转换）。
    def self.symbolize_keys(hash)
      hash.transform_keys(&:to_sym)
    end

    # 并行执行设备执行器。
    # 使用线程池，限制并发数。
    def self.parallel_execute(executors, max_concurrency, fail_fast)
      results = []
      mutex = Mutex.new
      queue = executors.dup
      threads = []

      # 限制并发线程数
      pool_size = max_concurrency || queue.size
      pool_size = [pool_size, queue.size].min

      pool_size.times do
        thread = Thread.new do
          loop do
            executor = mutex.synchronize { queue.pop }
            break unless executor

            # 执行单个设备
            device_result = executor.execute
            mutex.synchronize { results << device_result }

            # 如果 fail_fast 为真且该设备失败，则中断其他线程（通过清空队列）
            if fail_fast && !device_result[:success]
              mutex.synchronize { queue.clear }
            end
          end
        end
        threads << thread
      end

      threads.each(&:join)
      results
    end
  end
end
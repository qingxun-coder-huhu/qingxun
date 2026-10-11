# frozen_string_literal: true

require 'thread'

# 线程池执行器
# 管理20个工作线程，从队列中获取任务并执行
class ThreadPoolExecutor
  DEFAULT_POOL_SIZE = 20

  attr_reader :pool_size, :queue

  # @param pool_size [Integer] 线程池大小，默认20
  def initialize(pool_size = DEFAULT_POOL_SIZE)
    @pool_size = pool_size
    @queue = Queue.new
    @workers = []
    @running = false
    @mutex = Mutex.new
  end

  # 启动线程池
  def start
    @mutex.synchronize do
      return if @running
      @running = true
      spawn_workers
    end
  end

  # 停止线程池
  # @param wait [Boolean] 是否等待队列中的任务完成
  def stop(wait: true)
    @mutex.synchronize do
      return unless @running
      @running = false
      
      # 如果不等待，清空队列
      @queue.clear unless wait
      
      # 发送终止信号给所有线程
      @pool_size.times { @queue << :stop }
    end
    
    # 等待所有线程结束
    @workers.each(&:join)
    @workers.clear
  end

  # 提交任务到线程池
  # @param task [Proc] 要执行的任务块
  def submit(&task)
    raise ArgumentError, '必须提供任务块' unless block_given?
    @queue << task
  end

  # 获取队列中待处理的任务数量
  # @return [Integer]
  def queue_size
    @queue.size
  end

  # 检查线程池是否正在运行
  # @return [Boolean]
  def running?
    @mutex.synchronize { @running }
  end

  private

  # 生成工作线程
  def spawn_workers
    @pool_size.times do |i|
      worker = Thread.new(i) do |worker_id|
        worker_loop(worker_id)
      end
      @workers << worker
    end
  end

  # 工作线程主循环
  def worker_loop(worker_id)
    Thread.current[:name] = "Worker-#{worker_id}"
    
    while running?
      begin
        task = @queue.pop
        
        # 检查是否是停止信号
        break if task == :stop
        
        # 执行任务
        execute_task(task)
      rescue => e
        puts "[ThreadPoolExecutor] Worker-#{worker_id} 发生错误: #{e.class}: #{e.message}"
        puts e.backtrace.join("\n")
      end
    end
    
    puts "[ThreadPoolExecutor] Worker-#{worker_id} 已停止"
  end

  # 执行单个任务
  def execute_task(task)
    task.call
  rescue => e
    puts "[ThreadPoolExecutor] 任务执行失败: #{e.class}: #{e.message}"
    puts e.backtrace.join("\n")
    raise
  end
end

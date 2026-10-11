# frozen_string_literal: true

require 'spec_helper'
require 'qingxun/device_script'
require 'qingxun/connection_factory'
require 'qingxun/logger'
require 'qingxun/device_executor'
require 'qingxun/task_manager'
require 'fake_telnet_server'

RSpec.describe 'Qingxun 框架集成测试' do
  let(:scripts_dir) { 'spec/test_scripts' }
  let(:logs_dir) { 'spec/test_logs' }
  let(:server_port) { 23999 }
  let(:server) do
    FakeTelnetServer.new(
      port: server_port,
      username: 'testuser',
      password: 'testpass',
      enable_password: 'testenable'
    )
  end

  before do
    # 启动模拟服务器
    server.start
    # 等待服务器就绪
    sleep 0.1
  end

  after do
    server.stop
    # 清理日志目录
    FileUtils.rm_rf(logs_dir) if File.directory?(logs_dir)
  end

  # 创建一个简单的测试脚本
  before do
    FileUtils.mkdir_p(scripts_dir)
    File.write(File.join(scripts_dir, 'test_ping.rb'), <<~RUBY)
      require 'qingxun'
      class TestPing < Qingxun::DeviceScript
        def run(connection)
          log_info "测试脚本执行中"
          { result: 'pong' }
        end
      end
    RUBY
  end

  after do
    FileUtils.rm_rf(scripts_dir)
  end

  describe 'DeviceExecutor' do
    it '成功执行单个脚本' do
      device_config = {
        host: 'localhost',
        port: server_port,
        username: 'testuser',
        password: 'testpass',
        enable_command: 'enable',
        enable_password: 'testenable'
      }
      executor = Qingxun::DeviceExecutor.new(
        device_config,
        ['test_ping'],
        'test_task',
        scripts_dir: scripts_dir,
        logs_dir: logs_dir
      )

      result = executor.execute

      puts "调试结果: #{result.inspect}"
      expect(result[:success]).to be true
      expect(result[:device]).to eq('localhost')
      expect(result[:scripts].size).to eq(1)
      script_result = result[:scripts].first
      expect(script_result[:name]).to eq('test_ping')
      expect(script_result[:success]).to be true
      expect(script_result[:result]).to eq({ result: 'pong' })

      # 验证日志文件存在
      expect(File).to exist(File.join(logs_dir, 'test_task', 'localhost', 'login.log'))
      expect(File).to exist(File.join(logs_dir, 'test_task', 'localhost', 'scripts', 'test_ping.log'))
    end

    it '处理连接失败' do
      device_config = {
        host: 'localhost',
        port: 9999,  # 不存在端口
        username: 'testuser',
        password: 'testpass'
      }
      executor = Qingxun::DeviceExecutor.new(
        device_config,
        ['test_ping'],
        'test_task',
        scripts_dir: scripts_dir,
        logs_dir: logs_dir
      )

      result = executor.execute

      expect(result[:success]).to be false
      expect(result[:connection_status]).to eq(:failed)
      expect(result[:scripts]).to be_empty
    end
  end

  describe 'TaskManager' do
    it '并行执行多设备任务' do
      # 创建任务 JSON 文件
      task_json = {
        task_id: 'parallel_test',
        devices: [
          {
            host: 'localhost',
            port: server_port,
            username: 'testuser',
            password: 'testpass',
            enable_command: 'enable',
            enable_password: 'testenable'
          },
          {
            host: 'localhost',
            port: server_port,
            username: 'testuser',
            password: 'testpass',
            enable_command: 'enable',
            enable_password: 'testenable'
          }
        ],
        scripts: ['test_ping']
      }
      task_file = 'spec/temp_task.json'
      File.write(task_file, JSON.generate(task_json))

      begin
        result = Qingxun::TaskManager.run(task_file,
                                         scripts_dir: scripts_dir,
                                         logs_dir: logs_dir,
                                         max_concurrency: 2)

        expect(result[:success]).to be true
        expect(result[:total_devices]).to eq(2)
        expect(result[:succeeded_devices]).to eq(2)
        expect(result[:failed_devices]).to eq(0)
        expect(result[:devices].size).to eq(2)
      ensure
        File.delete(task_file) if File.exist?(task_file)
      end
    end
  end
end
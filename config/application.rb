require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Qingxun
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w(assets tasks))

    # 配置线程池大小（与 Puma 配置一致）
    config.max_threads = ENV.fetch("RAILS_MAX_THREADS") { 5 }
    config.active_record.encryption.hash_digest_class = OpenSSL::Digest::SHA256

    # 配置缓存存储为线程安全的
    config.cache_store = :memory_store, { size: 64 * 1000 * 1000 }

    # 配置 Active Job 队列适配器
    #
    # 用 Rails 内置的 :async（进程内线程池）。原先是 solid_queue：它当初是为结对编程引入的，
    # 而结对编程已整体移除、剩下的任务只有注册激活与找回密码两封邮件，它却常驻 6 个进程
    # （supervisor + 4 worker + dispatcher），实测白占 ~287MB 内存与空转时 ~121 次/秒的
    # 数据库轮询 —— 在这台 1.6GB 的机器上不划算。
    #
    # 隐性知识：
    #   1. :async 的任务在**进程内存**里，重启/部署会丢掉还没跑的（目前只有两封邮件，可接受）。
    #      要恢复持久化就装回 solid_queue —— solid_queue_* 的表与迁移都还在库里没删。
    #   2. 它同样跑在另一个线程里，线程局部变量过不去 → "需要 BYOK Key 的 LLM 调用必须在
    #      请求线程内完成"这条规矩没变（见 LlmApiKey）。
    #   3. `bin/rails runner` 里 deliver_later 会随进程退出而丢，命令行发信请用 deliver_now。
    config.active_job.queue_adapter = :async

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # 注册后自动登录（生产环境默认关闭）
    config.auto_login_after_registration = ENV.fetch('AUTO_LOGIN_AFTER_REGISTRATION', 'false') == 'true'

    # 添加请求ID跟踪中间件
    require_relative '../app/middleware/request_id_tracker'
    config.middleware.use RequestIdTracker
  end
end

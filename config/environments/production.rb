require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.
  # config.public_file_server.enabled = false

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and secure cookies.
  #
  # 隐性知识（实测踩过）：线上 nginx 的 vhost 只传了 Host / X-Real-IP / X-Forwarded-For，
  # **没有传 X-Forwarded-Proto**（仓库里的 setup_nginx_ssl.sh 模板是有的，线上那份没同步），
  # 于是 Rails 认为自己跑在 http 上，`request.base_url` 会生成 http://… 的地址。
  # 「云端改进」的一次性令牌就走 URL，http 意味着令牌会明文过一次网 ——
  # 被截到的人可以抢在用户之前把日志读走。所以这里打开 assume_ssl（TLS 由 nginx 终止，
  # 到容器这一段是明文且只在宿主内），让协议判定不再依赖那个缺失的请求头。
  # 另：不要顺手打开 force_ssl —— 在同样缺 X-Forwarded-Proto 的前提下，那会把
  # 每个请求都重定向到它自己（判定为 http → 跳 https → 仍判定为 http），变成死循环。
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = false

  # Log to STDOUT by default
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  # "info" includes generic and useful information about system operation, but avoids logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII). If you
  # want to log everything, set the level to "debug".
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Use a different cache store in production.
  # config.cache_store = :mem_cache_store

  # Use a real queuing backend for Active Job (and separate queues per environment).
  #
  # 与 application.rb 保持一致用 :async（进程内），不再起独立的队列进程：
  # 剩余任务只有注册激活/找回密码两封邮件，为它常驻 4 个 worker 不值得。详见 application.rb。
  config.active_job.queue_adapter = :async

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Enable DNS rebinding protection and other `Host` header attacks.
  if ENV["ALLOWED_HOSTS"].present?
    config.hosts = ENV["ALLOWED_HOSTS"].split(",").map(&:strip)
  end
  # Skip DNS rebinding protection for the default health check endpoint.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # 邮件：开源版没有账号体系，默认不发送邮件。如需启用，配置 SMTP_* 并设 MAIL_ENABLED=true。
  config.action_mailer.perform_deliveries = ENV.fetch('MAIL_ENABLED', 'false') == 'true'
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.default_url_options = {
    host: ENV.fetch('MAIL_HOST', 'localhost'),
    protocol: 'https'
  }
  config.action_mailer.smtp_settings = {
    address:         ENV.fetch('SMTP_ADDRESS', 'smtp.example.com'),
    port:            ENV.fetch('SMTP_PORT', 587).to_i,
    domain:          ENV.fetch('SMTP_DOMAIN', 'example.com'),
    user_name:       ENV.fetch('SMTP_USERNAME', nil),
    password:        ENV.fetch('SMTP_PASSWORD', nil),
    authentication:  ENV.fetch('SMTP_AUTHENTICATION', 'login').to_sym,
    enable_starttls: ENV.fetch('SMTP_ENABLE_STARTTLS', 'true') == 'true'
  }
end

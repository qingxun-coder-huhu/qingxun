source "https://rubygems.org"


# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 7.1.6"
# 队列已改用内置 :async 适配器，不再需要 solid_queue（原因见 config/application.rb）。
# 它的表与迁移仍保留在库里，将来要恢复持久化队列只需装回这个 gem。
gem "net-ssh", "~> 7.3"
gem "net-telnet"
gem "net-ssh-telnet", "~> 0.3"
# Use PostgreSQL as the database for Active Record
gem "pg", "~> 1.1"

# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ mswin mswin64 mingw x64_mingw jruby ]

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  # gem "debug", platforms: %i[ mri mswin mswin64 mingw x64_mingw ]
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # 邮件预览 - 在浏览器中预览发送的邮件
  gem "letter_opener"
  gem "letter_opener_web"

  # Add speed badges [https://github.com/MiniProfiler/rack-mini-profiler]
  # gem "rack-mini-profiler"

  # Speed up commands on slow machines / big apps [https://github.com/rails/spring]
  # gem "spring"

  # Load environment variables from .env file
  gem "dotenv-rails"

end

group :development, :test do
  gem 'byebug'
  gem 'rspec'
  
  gem 'pry'
end

group :test do
  gem 'rspec-rails'
end

gem "httparty", "~> 0.24.2"
# JWT 认证
gem "jwt", "~> 2.7"

# 安全中间件
gem "rack-cors"  # 跨域支持
gem "rack-attack" # 限流和防滥用

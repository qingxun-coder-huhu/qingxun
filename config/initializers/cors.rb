# 跨域资源共享 (CORS) 配置
#
# 生产环境建议通过环境变量配置允许的源
#
if defined?(Rack::Cors)
  Rails.application.config.middleware.insert_before 0, Rack::Cors do
    allow do
      origins do |source, env|
        # 开发环境允许所有来源
        if Rails.env.development? || Rails.env.test?
          true
        else
          # 生产环境检查来源是否在允许列表中
          allowed_hosts = ENV["ALLOWED_CORS_ORIGINS"]&.split(",")&.map(&:strip) || []
          allowed_hosts.include?(source)
        end
      end

      resource "*",
        headers: :any,
        methods: [:get, :post, :put, :patch, :delete, :options, :head],
        expose: ["Authorization", "Content-Type"],
        max_age: 600
    end
  end
end

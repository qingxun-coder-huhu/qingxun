# frozen_string_literal: true

module Qingxun
  module Integrations
    # Custom - 自定义集成
    #
    # 业务逻辑：
    #   - 服务端：加载用户生成的集成类代码，使用真实方法
    #   - 客户端：返回提示信息
    #
    class Custom < Base
      attr_accessor :user

      def initialize(user: nil, **kwargs)
        super(**kwargs)
        @user = user
      end

      # 动态响应所有函数调用
      def method_missing(name, *args, &block)
        if Qingxun::Integrations.server?
          call_generated_method(name, args)
        else
          client_mode_response(name, args.first || {})
        end
      end

      def respond_to_missing?(name, include_private = false)
        if Qingxun::Integrations.server?
          generated_instance&.respond_to?(name, false)
        else
          false
        end
      end

      private

      # 获取生成的集成实例（用于 respond_to_missing? 检查）
      def generated_instance
        return nil unless user
        load_generated_class(user.id)
      end

      # 调用用户生成的函数
      def call_generated_method(name, args)
        return { "success" => false, "error" => "User not set" } unless user

        integration = user.custom_integration
        return { "success" => false, "error" => "No integration found" } unless integration&.generated_code&.present?

        # 加载用户生成的类实例
        instance = load_generated_class(user.id)
        return { "success" => false, "error" => "Failed to load generated class" } unless instance

        # 调用方法
        instance.send(name, *args)
      rescue NoMethodError
        { "success" => false, "error" => "Method not found: #{name}" }
      end

      # 加载用户生成的类（带缓存）
      def load_generated_class(user_id)
        self.class.class_generated_classes[user_id] ||= load_and_cache_generated_class(user_id)
      end

      # 实际加载和缓存逻辑
      def load_and_cache_generated_class(user_id)
        # 获取用户集成代码
        integration = user.custom_integration
        return nil unless integration&.generated_code&.present?

        # 使用 load 方法安全地加载代码
        begin
          # 创建临时文件
          temp_dir = Rails.root.join('tmp', 'generated_integrations')
          FileUtils.mkdir_p(temp_dir)
          temp_file = temp_dir.join("custom_#{user_id}.rb")
          File.write(temp_file, integration.generated_code)

          # 加载文件
          load temp_file

          # 获取生成的类
          klass = Qingxun::Integrations::GeneratedCustom

          # 创建实例
          instance = klass.new(config: {user: user}, logger: @logger)
          instance
        rescue LoadError => e
          Rails.logger.error "[CustomIntegration] 加载用户代码失败: #{e.message}"
          nil
        end
      end

      # 类级别的缓存存储
      def self.class_generated_classes
        @class_generated_classes ||= {}
      end

      # 清除缓存
      def self.clear_cache!
        @class_generated_classes = {}
      end

      # 客户端响应
      def client_mode_response(function_name, params)
        {
          "error" => "Please implement custom integration in client",
          "function" => function_name,
          "params" => params
        }
      end
    end
  end
end

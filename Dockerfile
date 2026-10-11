# 清巡（Qingxun）开源版 · 生产镜像
#
# 用官方 ruby 镜像（不含国内私有 registry / 镜像源），依赖走 rubygems.org。
FROM ruby:3.2-slim

ENV RAILS_ENV=production \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_SILENCE_ROOT_WARNING=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RAILS_SERVE_STATIC_FILES=true \
    RAILS_LOG_TO_STDOUT=true

# libpq 是 pg gem 的运行/编译依赖；构建工具仅安装期需要
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential libpq-dev git curl ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 先装依赖，利用层缓存
COPY Gemfile Gemfile.lock ./
RUN gem install bundler -v 2.5.23 && bundle install --jobs 4 --retry 3

# 复制应用代码
COPY . .

RUN chmod +x bin/docker-entrypoint

EXPOSE 3000

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]

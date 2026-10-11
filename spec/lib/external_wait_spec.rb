# frozen_string_literal: true

require 'rails_helper'

# 外部等待期间归还数据库连接
#
# 背景（实测）：Rails 的连接按线程持有到请求结束，而一次生成要等约 40 秒（上限 300 秒）。
# pool 只有 5 个连接，5 个生成在飞就占满，第 6 个线程等 5 秒拿不到连接直接抛
# ActiveRecord::ConnectionTimeoutError（500）。所以等外部服务的那段要把连接还回池子。
RSpec.describe ExternalWait do
  # 本组不参与事务，否则"connection.transaction_open?"恒为真、归还逻辑被刻意跳过，
  # 就测不到真正要测的行为
  self.use_transactional_tests = false

  def pool
    ActiveRecord::Base.connection_pool
  end

  it '无事务时把连接还回池子（归还后本线程下次访问数据库会自动重新借出）' do
    ActiveRecord::Base.connection
    expect(pool.active_connection?).to be_truthy

    described_class.without_db_connection do
      expect(pool.active_connection?).to be_nil
      expect(pool.stat[:busy]).to eq(0)
    end

    # 块结束后并不需要显式借回：访问数据库就会自动 checkout
    expect(User.count).to be_a(Integer)
    expect(pool.active_connection?).to be_truthy
  end

  # 连接带着未提交的事务回到池子会被别的线程借走（或本线程再借到另一条、事务直接断开）。
  # 这条既是生产安全网，也是"别把生成放进事务"的守门。
  it '事务中绝不归还' do
    ActiveRecord::Base.transaction do
      described_class.without_db_connection do
        expect(pool.active_connection?).to be_truthy
      end
    end
  end
end

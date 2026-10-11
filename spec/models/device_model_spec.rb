# frozen_string_literal: true

require 'rails_helper'

# 用户维护的设备型号
#
# 这里钉住的契约：
#   1. 型号是**用户私有**的：不同用户可以有同名型号，同一用户不能重复（大小写不敏感）；
#   2. 名称两端空白会被去掉（手输最常见的脏数据）；
#   3. 默认顺序按名称忽略大小写升序 —— 管理页与生成页下拉共用，必须稳定可预期。
RSpec.describe DeviceModel do
  def anonymous_user
    User.local_operator
  end

  describe '校验' do
    it '名称为空则无效' do
      model = described_class.new(user: anonymous_user, name: '   ')
      expect(model).not_to be_valid
      expect(model.errors[:name]).to be_present
    end

    it '保存时去掉名称两端空白' do
      model = described_class.create!(user: anonymous_user, name: '  Cisco Catalyst 2960  ')
      expect(model.reload.name).to eq('Cisco Catalyst 2960')
    end

    it '同一用户下名称重复（忽略大小写与空白）无效' do
      user = anonymous_user
      described_class.create!(user: user, name: 'Huawei S5735')

      duplicate = described_class.new(user: user, name: 'huawei s5735  ')
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

  end

  describe '.ordered' do
    it '按名称忽略大小写升序' do
      user = anonymous_user
      described_class.create!(user: user, name: 'Huawei S5735')
      described_class.create!(user: user, name: 'cisco 2960')
      described_class.create!(user: user, name: 'H3C S5120')

      expect(described_class.ordered.pluck(:name)).to eq(['cisco 2960', 'H3C S5120', 'Huawei S5735'])
    end

  end
end

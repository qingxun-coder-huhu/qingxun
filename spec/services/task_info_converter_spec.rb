# frozen_string_literal: true

require 'rails_helper'

# TaskInfoConverter 逐字复用自客户端 net_cat_client/lib/task_info_converter.rb
RSpec.describe TaskInfoConverter do
  let(:input_data) do
    {
      'Cisco Catalyst 2960' => {
        'devs' => [{
          'id' => '4a891589-ebe9-4914-8b39-1bb928dfc7ac',
          'name' => '测试交换机',
          'device_type' => 'switch',
          'device_model' => 'Cisco Catalyst 2960',
          'description' => '测试用网络交换机'
        }],
        'scripts' => [{
          'id' => 25,
          'name' => '测试4',
          'device_types' => [],
          'device_models' => ['Cisco Catalyst 2960'],
          'description' => '该脚'
        }]
      }
    }
  end

  it '转换按型号分组的格式为标准格式' do
    converted = described_class.convert(input_data)

    expect(converted[:devices].size).to eq(1)
    expect(converted[:scripts].size).to eq(1)
    expect(converted[:devices][0]['name']).to eq('测试交换机')
    expect(converted[:scripts][0]['name']).to eq('测试4')
  end

  it '剥掉 task_json 包装层' do
    converted = described_class.convert(task_json: input_data)
    expect(converted[:devices][0]['id']).to eq('4a891589-ebe9-4914-8b39-1bb928dfc7ac')
    expect(converted[:scripts][0]['id']).to eq(25)
  end

  it '支持简单的 devices/scripts 平铺格式' do
    converted = described_class.convert('devices' => [{ 'id' => 1 }], 'scripts' => [{ 'id' => 2 }])
    expect(converted[:devices]).to eq([{ 'id' => 1 }])
    expect(converted[:scripts]).to eq([{ 'id' => 2 }])
  end

  it '按 id 去重' do
    dup = { 'A' => { 'devs' => [{ 'id' => 1 }], 'scripts' => [{ 'id' => 2 }] },
            'B' => { 'devs' => [{ 'id' => 1 }], 'scripts' => [{ 'id' => 2 }] } }
    converted = described_class.convert(dup)
    expect(converted[:devices].size).to eq(1)
    expect(converted[:scripts].size).to eq(1)
  end

  it '非 Hash 输入返回空结构' do
    expect(described_class.convert(nil)).to eq(devices: [], scripts: [])
    expect(described_class.convert('oops')).to eq(devices: [], scripts: [])
  end
end

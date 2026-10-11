# frozen_string_literal: true

require 'rails_helper'

# 脚本开发全流程帮助页（/guide）
#
# 这一页要讲清「手工日志 → 调试完成」的八步闭环，内容多、锚点多、链接多，最容易在后续改文案时
# 悄悄烂掉。这里钉住四件事：
#   1. **不登录也能打开**——它要在用户注册/填 Key 之前就发挥作用，被 require_login 挡掉就白做了；
#   2. 八个步骤的锚点齐全，且页面里所有页内锚点都指向真实存在的节点（此前改版踩过目录指向空节点）；
#   3. 它讲的按钮名必须是产品里真实存在的文案，否则用户照着找不着；
#   4. 与《如何编写描述》互相链接、导航栏有入口——否则页面存在但没人找得到。
RSpec.describe '脚本开发全流程帮助页', type: :request do
  it '未登录即可访问' do
    get '/guide'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('这是清巡推荐的脚本开发流程')
  end

  it '八个步骤的锚点齐全' do
    get '/guide'

    (1..8).each { |n| expect(response.body).to include(%(id="step-#{n}")) }
  end

  it '页内锚点都指向真实存在的节点' do
    get '/guide'

    anchors = response.body.scan(/href="#([a-z0-9-]+)"/).flatten.uniq
    expect(anchors).not_to be_empty
    anchors.each do |id|
      expect(response.body).to include(%(id="#{id}")), "锚点 ##{id} 没有对应的节点"
    end
  end

  it '步骤里引用的按钮文案与产品一致' do
    get '/guide'

    %w[从手工日志生成 自动化生成 调试完成 云端改进].each do |label|
      expect(response.body).to include(label)
    end
  end

  it '导航栏有入口，描述写法帮助页能跳回本页' do
    get '/guide'
    expect(response.body).to include('使用指南')

    get '/script_generation_help'
    expect(response.body).to include('/guide')
  end
end

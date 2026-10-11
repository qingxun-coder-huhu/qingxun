# frozen_string_literal: true

require 'rails_helper'

# 脚本自动保存与版本历史
#
# 背景：生成脚本页此前只有"手动保存"，刷新就丢；现在生成/微调结束与编辑时自动落库，并把每次
# 有意义的内容变更记成版本快照，页面可查看与回滚。这里钉住的是**接口契约与状态语义**：
#   1. 自动保存按 script_uid upsert，但**不动** publish_status 与 tags——那是"手动保存"的语义，
#      沿用它会让用户一边输入一边把"调试完成"打掉；
#   2. 首次自动保存会新建一行 scripts（占用脚本配额），配额不足时明确报错而不是静默丢弃；
#   3. 历史只能看自己脚本的（越权 uid 一律"不存在"）；
#   4. 回滚 = 内容写回 + 记一条 source=rollback 的新版本 + 状态退回"调试中"。
RSpec.describe '脚本自动保存与版本历史', type: :request do
  let(:script_uid) { SecureRandom.hex(8) }
  let(:base_code) { "class DemoS < Qingxun::DeviceScript\n  def run; end\nend" }
  # 命令映射用数组形态（页面实际下发的就是数组）。Hash 形态要求键与值都是字符串，
  # 写成 {"commands":[]} 会被 Script#validate_command_mapping_format 拒掉。
  let(:mapping_json) { [{ 'command' => 'show version', 'response' => 'Version 1.0' }].to_json }

  # 用真实入口建立会话：领识别码 → /onboarding/enter。
  # 不直接塞 session，是因为这条路径同时决定 activated（未激活会被 require_login 挡成 403）。
  def sign_in_user
    # 开源版免登录：所有请求都以本地操作员身份运行。
    User.local_operator
  end

  def autosave(overrides = {})
    post '/scripts/autosave', params: {
      script_uid: script_uid,
      script_name: '巡检脚本',
      script_description: '测试脚本',
      initial_prompt: '检查设备版本',
      device_models: 'ZXCTN 9000',
      code: base_code,
      command_mapping: mapping_json,
      branch_scenarios: '[]',
      source: 'generated'
    }.merge(overrides), as: :json
  end

  describe 'POST /scripts/autosave' do

    it '首次自动保存新建脚本并记 r1' do
      user = sign_in_user
      autosave

      body = JSON.parse(response.body)
      expect(body['success']).to be(true)
      expect(body['revision']).to eq(1)

      script = user.scripts.find_by(script_uid: script_uid)
      expect(script).to be_present
      expect(script.reload.revision).to eq(1)
      expect(script.script_versions.count).to eq(1)
      expect(script.script_versions.first.source).to eq('generated')
    end

    # 版本由"描述"驱动：同一份描述下改代码只是刷新当前版本，不该冒出第二条历史
    it '描述没变时只刷新当前版本，不新增历史' do
      user = sign_in_user
      autosave
      autosave(code: "#{base_code}\n# 改了一行")

      script = user.scripts.find_by(script_uid: script_uid)
      expect(user.scripts.where(script_uid: script_uid).count).to eq(1)
      expect(script.script_versions.count).to eq(1)
      expect(script.script_versions.first.code).to include('改了一行')
      expect(script.revision).to eq(1)
    end

    it '描述变了才新增一版' do
      user = sign_in_user
      autosave
      autosave(initial_prompt: '改过的需求：只看 CPU', code: "#{base_code}\n# 改了一行", source: 'refined')

      script = user.scripts.find_by(script_uid: script_uid)
      expect(script.script_versions.count).to eq(2)
      expect(script.revision).to eq(2)
      expect(script.script_versions.recent.first.source).to eq('refined')
    end

    # 这条是产品决定的关键：自动保存只写内容，不替用户改状态
    it '不改动 publish_status 与 tags' do
      user = sign_in_user
      script = user.scripts.create!(
        name: '已调试脚本', description: 'x', code: base_code, version: '1.0.0',
        device_models: ['ZXCTN 9000'], user_id: user.id,
        script_uid: script_uid, publish_status: :debugged, tags: ['debugged']
      )

      autosave(code: "#{base_code}\n# 自动保存追加")

      script.reload
      expect(script.publish_status).to eq('debugged')
      expect(script.tags).to eq(['debugged'])
      expect(script.code).to include('自动保存追加')
    end

    it '内容完全没变时不新增版本（编辑防抖不该刷出空历史）' do
      sign_in_user
      autosave
      autosave

      expect(ScriptVersion.count).to eq(1)
    end

    it '缺少脚本标识或还没有代码时返回 422' do
      sign_in_user
      autosave(script_uid: '')
      expect(response).to have_http_status(:unprocessable_entity)

      autosave(code: '')
      expect(response).to have_http_status(:unprocessable_entity)
    end

    # 型号只在"调试完成"时才必须给：草稿要能先存下来（更新要求：首次落库不等型号）
    it '型号还空着也能首次落库（草稿），标记调试完成时才被拒' do
      user = sign_in_user
      autosave(device_models: '')

      expect(response).to have_http_status(:ok)
      script = user.scripts.find_by(script_uid: script_uid)
      expect(script).to be_present
      expect(script.device_models).to eq([])
      expect(script.publish_status).to eq('debugging')

      post '/scripts/debug_complete', params: {
        script_uid: script_uid, script_name: '巡检脚本', script_description: '测试脚本',
        initial_prompt: '检查设备版本', device_models: '', code: base_code,
        command_mapping: mapping_json, branch_scenarios: '[]'
      }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('设备型号')
      expect(script.reload.publish_status).to eq('debugging')
    end

    # 实测踩过：script_versions 表还没建（迁移没跑）时，写版本抛 PG::UndefinedTable，
    # 整个请求变成 500 错误页——内容其实已经存进去了，用户却看到"自动保存失败"。
    # 自动保存的首要是别丢内容，历史写失败只降级、不许连累保存。
    it '历史写失败时内容仍然保存，并如实回报未记入历史' do
      user = sign_in_user
      allow(ScriptVersionRecorder).to receive(:record)
        .and_raise(ActiveRecord::StatementInvalid.new('relation "script_versions" does not exist'))

      autosave

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['success']).to be(true)
      expect(body['history_saved']).to be(false)
      expect(user.scripts.find_by(script_uid: script_uid)).to be_present
    end
  end

  describe 'GET /scripts/versions 与 /scripts/version' do
    it '列表只回摘要，详情才带代码' do
      user = sign_in_user
      autosave
      # 第二条版本得靠「描述变了」产生：同一描述下改代码只刷新当前版本
      autosave(initial_prompt: '改过的需求：只看 CPU', code: "#{base_code}\n# 第二版", source: 'refined')
      script = user.scripts.find_by(script_uid: script_uid)

      get '/scripts/versions', params: { script_uid: script_uid }, as: :json
      list = JSON.parse(response.body)
      expect(list['success']).to be(true)
      expect(list['revision']).to eq(2)
      expect(list['data'].map { |v| v['revision'] }).to eq([2, 1])
      expect(list['data'].first['source_label']).to eq('微调')
      expect(list['data'].first).not_to have_key('code')
      # 列表第二行要能看出"这一版要做什么"，所以给的是主线描述摘要而不是代码/名称
      expect(list['data'].first['initial_prompt_excerpt']).to eq('改过的需求：只看 CPU')
      expect(list['data'].last['initial_prompt_excerpt']).to eq('检查设备版本')
      expect(list['data'].first).not_to have_key('initial_prompt')

      get '/scripts/version', params: { script_uid: script_uid, version_id: list['data'].last['id'] }, as: :json
      detail = JSON.parse(response.body)['data']
      expect(detail['code']).to eq(base_code)
      expect(detail['revision']).to eq(1)
    end

    # 版本由描述驱动，所以详情里的差异要看得出"哪个分支的描述改了什么"
    it '详情带与上一版的差异，并分清新分支/删除分支/改描述' do
      user = sign_in_user
      autosave(branch_scenarios: [
                 { 'name' => '分支A', 'description' => '端口全 up' },
                 { 'name' => '分支B', 'description' => '旧场景' }
               ].to_json)
      autosave(branch_scenarios: [
                 { 'name' => '分支A', 'description' => '端口有 down' },
                 { 'name' => '分支C', 'description' => '新场景' }
               ].to_json,
               initial_prompt: '改过的需求：看端口', source: 'refined')
      script = user.scripts.find_by(script_uid: script_uid)

      get '/scripts/version',
          params: { script_uid: script_uid, version_id: script.script_versions.find_by(revision: 2).id }, as: :json
      diff = JSON.parse(response.body)['diff']
      expect(diff['first']).to be(false)
      expect(diff['from_revision']).to eq(1)
      expect(diff['branches']['changed']).to eq([
                                                  { 'name' => '分支A', 'before' => '端口全 up', 'after' => '端口有 down' }
                                                ])
      expect(diff['branches']['added']).to eq([{ 'name' => '分支C', 'description' => '新场景' }])
      expect(diff['branches']['removed']).to eq([{ 'name' => '分支B', 'description' => '旧场景' }])
      expect(diff['mainline']['changed']).to be(true)

      # 第一版没有可对比的上一版
      get '/scripts/version',
          params: { script_uid: script_uid, version_id: script.script_versions.find_by(revision: 1).id }, as: :json
      expect(JSON.parse(response.body)['diff']['first']).to be(true)
    end

it '主线描述很长时列表只回摘要，完整文本留在详情里' do
  user = sign_in_user
  long_prompt = "目标：核对端口状态。" * 40   # 400 字，远超摘要长度
  autosave(initial_prompt: long_prompt)
  script = user.scripts.find_by(script_uid: script_uid)

  get '/scripts/versions', params: { script_uid: script_uid }, as: :json
  excerpt = JSON.parse(response.body)['data'].first['initial_prompt_excerpt']
  expect(excerpt.length).to eq(ScriptsController::VERSION_EXCERPT_LENGTH + 1) # 摘要 + 省略号
  expect(excerpt).to end_with('…')
  expect(excerpt).not_to include("\n")   # 换行会撑高列表项

  get '/scripts/version', params: { script_uid: script_uid, version_id: script.script_versions.first.id }, as: :json
  expect(JSON.parse(response.body)['data']['initial_prompt']).to eq(long_prompt)
end

    it '别人的脚本标识一律当作不存在' do
      sign_in_user
      other = User.new(email: "other_#{SecureRandom.hex(6)}@example.com",
                       password: 'password123', password_confirmation: 'password123')
      other.save!(validate: false)
      other_script = Script.create!(
        name: '别人的脚本', description: 'x', code: base_code, version: '1.0.0',
        device_models: [], user_id: other.id, script_uid: SecureRandom.hex(8)
      )
      ScriptVersionRecorder.record(other_script, source: 'generated', user: other)

      get '/scripts/versions', params: { script_uid: other_script.script_uid }, as: :json
      expect(response).to have_http_status(:not_found)

      get '/scripts/version', params: { script_uid: other_script.script_uid, version_id: other_script.script_versions.first.id }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /scripts/rollback' do
    it '把旧内容写回当前、记一条 rollback 版本，并把状态退回调试中' do
      user = sign_in_user
      autosave
      autosave(code: "#{base_code}\n# 第二版", source: 'refined',
              initial_prompt: '改过的需求：只看 CPU')
      script = user.scripts.find_by(script_uid: script_uid)
      script.update!(publish_status: :debugged, tags: ['debugged'])
      first_version = script.script_versions.find_by(revision: 1)

      post '/scripts/rollback', params: { script_uid: script_uid, version_id: first_version.id }, as: :json

      body = JSON.parse(response.body)
      expect(body['success']).to be(true)
      expect(body['rolled_back_from']).to eq(1)
      expect(body['data']['code']).to eq(base_code)

      script.reload
      expect(script.code).to eq(base_code)
      # 主线描述也要还原，否则页面呈现"旧代码 + 新需求"
      expect(script.initial_prompt).to eq('检查设备版本')
      expect(script.publish_status).to eq('debugging')   # 内容变了就不再是"已验证"
      expect(script.revision).to eq(3)
      expect(script.script_versions.recent.first.source).to eq('rollback')
    end

    it '版本不存在时返回 404' do
      sign_in_user
      autosave

      post '/scripts/rollback', params: { script_uid: script_uid, version_id: 999_999 }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe '已有动作也会留下版本' do
    it '手动保存记 source=manual' do
      user = sign_in_user
      post '/scripts/save', params: {
        script_uid: script_uid, script_name: '巡检脚本', script_description: '测试脚本',
        initial_prompt: '检查设备版本', device_models: 'ZXCTN 9000', code: base_code,
        command_mapping: mapping_json, branch_scenarios: '[]'
      }, as: :json

      script = user.scripts.find_by(script_uid: script_uid)
      expect(JSON.parse(response.body)['success']).to be(true)
      expect(script.script_versions.first.source).to eq('manual')
      expect(script.script_versions.first.revision).to eq(1)
    end

    # 型号的必填要求只留在「调试完成」那一关：保存/自动保存出来的都是草稿，
    # 否则会出现"自动保存成功了、点保存却说型号不能为空"的矛盾
    it '手动保存也允许草稿没有型号' do
      user = sign_in_user
      post '/scripts/save', params: {
        script_uid: script_uid, script_name: '巡检脚本', script_description: '测试脚本',
        initial_prompt: '检查设备版本', device_models: '', code: base_code,
        command_mapping: mapping_json, branch_scenarios: '[]'
      }, as: :json

      expect(response).to have_http_status(:ok)
      script = user.scripts.find_by(script_uid: script_uid)
      expect(script.device_models).to eq([])
      expect(script.publish_status).to eq('debugging')
    end

    # 只变状态不加版本：按「描述驱动」的模型，它只是刷新当前版本（source 保持最初来源）
    it '标记调试完成只刷新当前版本，不新增历史' do
      user = sign_in_user
      autosave
      post '/scripts/debug_complete', params: {
        script_uid: script_uid, script_name: '巡检脚本', script_description: '测试脚本',
        initial_prompt: '检查设备版本', device_models: 'ZXCTN 9000', code: base_code,
        command_mapping: mapping_json, branch_scenarios: '[]'
      }, as: :json

      script = user.scripts.find_by(script_uid: script_uid)
      expect(script.publish_status).to eq('debugged')
      expect(script.script_versions.count).to eq(1)
      expect(script.script_versions.recent.first.publish_status).to eq('debugged')
    end
  end
end

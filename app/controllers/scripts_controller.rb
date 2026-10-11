# frozen_string_literal: true

require_relative '../services/auto_generate_service'
require_relative '../services/branch_suggestion_service'
require_relative '../services/branch_consistency_service'
require_relative '../services/branch_mapping_generation_service'
require_relative '../services/debug_session'
require_relative '../services/script_evaluation_service'
require_relative '../services/script_requirement_draft_service'
require_relative '../services/script_version_recorder'

# ScriptsController 负责处理脚本生成和调试的页面请求。
# 业务逻辑：
#   - 用户通过自然语言描述请求生成脚本。
#   - 调用 ScriptGenerationService 生成 Ruby 代码。
#   - 用户可以对生成的代码进行调试（在沙盒中执行）。
#   - 自动化流程：生成→测试→评估→重试（最多3次）。
#   - 返回 JSON 响应供前端动态更新页面。
#
# 隐性知识：
#   - 生成的脚本数据库。
#   - 调试会话使用 FakeTelnetServer 模拟设备，使用默认连接参数（localhost:2323）。
#   - 错误处理：捕获服务层异常，返回包含错误信息的 JSON 响应。
#   - 用户认证：支持匿名使用，但登录用户可保存脚本到数据库
class ScriptsController < ApplicationController
  # 版本历史列表一次最多返回多少条（取最近的）
  VERSION_LIST_LIMIT = 50

  # 列表里主线描述的摘要长度。
  #
  # 隐性知识：列表要让人一眼看出"这一版要做什么"，所以每条的第二行放**主线描述**而不是
  # 代码或名称；但主线描述动辄上千字（那段"步骤 + 命令 + 回显 + 判据"），几十条一起返回
  # 会把响应撑大几十倍，所以这里截断成摘要——完整文本在单条详情里（/scripts/version）。
  VERSION_EXCERPT_LENGTH = 120

  # 代码框的占位文案：前端用它判断"还没有生成结果"，自动保存要拒绝把占位当代码存下来。
  # 这个字符串与视图里的 #generated-code 初始内容必须一致，改一处要改两处。
  PLACEHOLDER_CODE_PREFIX = '# 生成的脚本将显示在这里'

  # 「自定义分支场景」输入的长度上限：这段文本原样进提示词，超长会抬高 token 成本。
  MAX_CUSTOM_REQUIREMENT_LENGTH = 2000

  # 脚本生成页允许**匿名访问**。
  #
  # 业务逻辑：用户在本页填写需求描述，由大模型生成脚本并自测。
  # 开源版免登录：本页与所有写操作都直接以本地操作员身份运行。
  #
  # 隐性知识：生成用的 LLM Key 由服务端配置（config/qingxun.yml）提供，
  # 页面不再要求用户填写 Key。

     # 显示主页面（包含输入表单、代码编辑器和调试面板）
    def index
      # 如果用户已登录，检查是否需要新建脚本或加载特定脚本
      if logged_in?
        # 按 script_uid 加载（生成页的身份统一用它：URL、保存、历史都是）；script_id 只作为
        # 旧链接/旧书签的兼容回退。用 uid 的好处是它在建行之前就存在，刷新页面不会换身份。
        if params[:script_uid].present?
          @debugging_script = current_user.scripts.find_by(script_uid: params[:script_uid].to_s.strip)
        elsif params[:script_id].present?
          @debugging_script = current_user.scripts.find_by(id: params[:script_id])
        end
        if @debugging_script
          @latest_command_mapping = @debugging_script.command_mappings.order(created_at: :desc).first
        end
      end
      # 说明：原「从结对编程会话带入描述」的入口已随结对编程功能移除。

      # 页面初始化即确定脚本唯一标识：加载老脚本沿用其 uid，新脚本新生成。
      # 生成出的脚本类名后缀与保存时的定位都用它。
      #
      # 隐性知识：URL 里带来的 uid 要认（页面加载时就把它写进地址栏了），否则刷新一次就换身份、
      # 草稿与历史全对不上——那是"一刷新历史就没了"的根因。但只接受**格式合法且未被占用**的 uid：
      # 格式不对会让它进类名后缀；已被别人占用则保存时会撞 script_uid 唯一索引。
      @script_uid = @debugging_script&.script_uid.presence ||
                    adoptable_uid_param ||
                    Script.generate_unique_uid

      # 首页 Hero「生成需求描述」表单 POST 过来的目标与日志：不落库、不落浏览器存储，
      # 只在这两次渲染里注入（见视图里的 #draft-prefill）。
      @draft_prefill = draft_prefill_from_params

      # 「支持的设备型号」下拉的候选：用户自己维护的型号清单（见 DeviceModel）。
      #
      # 隐性知识：本页允许匿名访问，匿名用户还没有 current_user，这里退化成空候选——
      # 但输入框仍可自由输入并回车新增，所以免注册流程照常可用（不因清单为空而被卡住）。
      @device_model_options = logged_in? ? current_user.device_models.ordered.pluck(:name) : []
    end

  # 我的脚本页面
  # GET /scripts/my_scripts
  #
  # 搜索走前端（见视图里的 script-search）：本页一次性渲染全部脚本、无分页，
  # 前端过滤即可覆盖全部数据，且能同时匹配名称/描述/设备型号而无需往返服务端。
  def my_scripts
    unless logged_in?
      redirect_to scripts_path, alert: '请先填写 LLM API Key 或录入识别码'
      return
    end

    all_scripts = current_user.scripts
    @total_count = all_scripts.count
    @debugged_count = all_scripts.debugged.count
    @debugging_count = all_scripts.debugging.count

    @scripts = all_scripts.order(updated_at: :desc)
  end

  # 删除脚本
  # DELETE /scripts/:id
  def destroy
    unless logged_in?
      redirect_to scripts_path, alert: '请先填写 LLM API Key 或录入识别码'
      return
    end

    @script = current_user.scripts.find(params[:id])
    @script.destroy

    redirect_to my_scripts_scripts_path, notice: '脚本删除成功'
  rescue ActiveRecord::RecordNotFound
    redirect_to my_scripts_scripts_path, alert: '脚本不存在或您没有权限删除'
  end

  # 生成脚本
  # POST /scripts/generate
  # 参数：{ description: "自然语言描述"}
  def generate
    description = params.require(:description)

    service = ScriptGenerationService.new(description, user: current_user)
    result = service.call
    
    # 返回生成的脚本内容、映射内容、简短描述，不再返回文件名
    render json: { 
      success: true, 
      code: result[:code], 
      command_mapping: result[:command_mapping], 
      description: result[:description]
    }
  rescue => e
    render json: { success: false, error: e.message, backtrace: e.backtrace }, status: :unprocessable_entity
  end

  # 保存当前脚本
  # POST /scripts/save
  def save
    unless logged_in?
      return render json: { success: false, error: '请先登录' }, status: :unauthorized
    end

    script_name = params[:script_name]
    script_description = params[:script_description]
    code = params[:code]
    device_models = params[:device_models]
    command_mapping = params[:command_mapping]
    sandbox_debug_log = params[:sandbox_debug_log]
    debug_execution_result = params[:debug_execution_result]

    # 验证必填字段
    if code.blank?
      return render json: { success: false, error: '脚本代码不能为空' }, status: :unprocessable_entity
    end
    if script_name.blank?
      return render json: { success: false, error: '脚本名称不能为空' }, status: :unprocessable_entity
    end
    # 「支持的设备型号」不在这里必填：保存出来的是草稿（调试中），型号的必填要求放在
    # 「调试完成」那一步（见 Script#validate_device_models 与 debug_complete）。
    # 否则会出现"自动保存成功了、点保存却说型号不能为空"的自相矛盾。

    # 按脚本唯一标识查找（当前用户范围内）；未命中即视为新脚本
    script_uid = params[:script_uid].to_s.strip
    script_uid = Script.generate_unique_uid if script_uid.empty?
    existing_script = current_user.scripts.find_by(script_uid: script_uid)

    script = existing_script || current_user.scripts.new(publish_status: :debugging)

    # 处理设备型号
    final_device_models = if device_models.present?
                          device_models.split(',').map(&:strip).reject(&:empty?)
                        else
                          []
                        end

      # 解析命令映射
    parsed_command_mapping = if command_mapping.present?
                                begin
                                  JSON.parse(command_mapping)
                                rescue JSON::ParserError
                                  {}
                                end
                              else
                                {}
                              end

    # 解析调试执行结果（仅用于留存调试信息，不再据此决定状态）
    if debug_execution_result.present?
      begin
        JSON.parse(debug_execution_result)
      rescue JSON::ParserError
        # 如果解析失败，忽略
      end
    end

       # 更新脚本属性
    script.assign_attributes(
      name: script_name,
      description: script_description.presence || '用户保存的脚本',
      initial_prompt: params[:initial_prompt] || '',
      code: code,
      version: script.version || '1.0.0',
      command_mapping: parsed_command_mapping,
      device_models: final_device_models,
      tags: ['saved', 'manual'],
      # 保存意味着脚本内容可能已变更，状态一律回到"未调试"；
      # 是否调试完成由用户在保存后的提示里确认（或之后点「调试完成」）。
      publish_status: :debugging,
      # 身份标识：按 uid 定位，同名脚本互不影响
      script_uid: script_uid
    )

     # 分支覆盖场景（名称/描述/映射/通过与否）
     branch_scenarios = parse_branch_scenarios_param
     script.branch_scenarios = branch_scenarios if branch_scenarios

     if script.save
       # 保存命令映射（包含调试信息）
       if sandbox_debug_log.present? || debug_execution_result.present?
         command_mapping_record = script.command_mappings.create(
           prompt: params[:initial_prompt] || '',
           mapping_file: command_mapping,
           sandbox_debug_log: sandbox_debug_log,
           debug_execution_result: debug_execution_result
         )
       end

       # 手动保存也进版本历史：它是用户明确的一次动作，合并不但省不下多少，
       # 还会让"我明明点了保存，历史里却没有"变成新的困惑
       version = record_version(script, 'manual')

       render json: { success: true, message: '保存成功', script_id: script.id,
                      revision: version&.revision, history_saved: version.present?,
                      version: script.version }
     else
       render json: { success: false, error: script.errors.full_messages.join(', ') }, status: :unprocessable_entity
     end
   rescue => e
     render json: { success: false, error: e.message }, status: :unprocessable_entity
   end

     # 调试完成脚本
     # POST /scripts/debug_complete
     def debug_complete
       unless logged_in?
         return render json: { success: false, error: '请先登录' }, status: :unauthorized
       end

       script_id = params[:script_id]
       script_uid = params[:script_uid].to_s.strip
       script_name = params[:script_name]
       script_description = params[:script_description]
       code = params[:code]
       device_models = params[:device_models]
       command_mapping = params[:command_mapping]

        # 按脚本唯一标识查找；uid 缺失时兼容旧的 script_id / "未调试" 兜底
        script = if script_uid.present?
                  current_user.scripts.find_by(script_uid: script_uid)
                elsif script_id.present?
                  current_user.scripts.find_by(id: script_id)
                else
                  current_user.scripts.debugging.first
                end

        script ||= current_user.scripts.new
        # 新记录要沿用页面带来的标识，避免 identity 变成另一个脚本
        script.script_uid = script_uid if script.script_uid.blank? && script_uid.present?

        # 验证必填字段（使用现有脚本的属性如果参数未提供）
        final_code = code.presence || script.code
        final_script_name = script_name.presence || script.name
        final_script_description = script_description.presence || script.description
        final_device_models_str = device_models.presence || (script.device_models.present? ? script.device_models.join(', ') : '')

        if final_code.blank?
          return render json: { success: false, error: '脚本代码不能为空' }, status: :unprocessable_entity
        end
        if final_script_name.blank?
          return render json: { success: false, error: '脚本名称不能为空' }, status: :unprocessable_entity
        end
        if final_script_description.blank?
          return render json: { success: false, error: '脚本描述不能为空' }, status: :unprocessable_entity
        end
        if final_device_models_str.blank?
          return render json: { success: false, error: '支持的设备型号不能为空' }, status: :unprocessable_entity
        end

      # 处理设备型号
      final_device_models = if final_device_models_str.present?
                             final_device_models_str.split(',').map(&:strip).reject(&:empty?)
                           else
                             []
                           end

      # 解析命令映射
      parsed_command_mapping = if command_mapping.present?
                                 begin
                                   JSON.parse(command_mapping)
                                 rescue JSON::ParserError
                                   {}
                                 end
                               else
                                 script.command_mapping || {}
                               end

      # 更新脚本属性并标记为调试完成
      script.assign_attributes(
        name: final_script_name,
        description: final_script_description,
        initial_prompt: params[:initial_prompt] || script.initial_prompt || '',
        code: final_code,
        version: script.version || '1.0.0',
        command_mapping: parsed_command_mapping,
        device_models: final_device_models,
        tags: ['debugged'],
        publish_status: :debugged,
        script_uid: script_uid.presence || script.script_uid
      )

      # 分支覆盖场景（名称/描述/映射/通过与否）
      branch_scenarios = parse_branch_scenarios_param
      script.branch_scenarios = branch_scenarios if branch_scenarios

      if script.save
        # 标记调试完成时内容通常没变（保存时已记过），ScriptVersionRecorder 会按内容去重，
        # 这里仍显式记一次：状态变更本身也是"这个版本被认可了"的边界
        version = record_version(script, 'debugged')

        render json: { success: true, message: '调试完成', script_id: script.id,
                       revision: version&.revision, history_saved: version.present? }
      else
        render json: { success: false, error: script.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    rescue => e
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    end

   # 自动保存
   # POST /scripts/autosave
   #
   # 业务逻辑：
   #   自动生成/微调结束、以及用户编辑名称/描述/型号时由前端防抖调用。按 script_uid
   #   upsert 当前内容，并留一条 source=autosave 的版本快照（同来源 2 分钟内合并，
   #   内容没变不记，见 ScriptVersionRecorder）。
   #
   # 隐性知识：
   #   1. 这里**故意不动 publish_status 与 tags**。/scripts/save 会把状态一律打回"未调试"，
   #      那是"用户主动保存"的语义；自动保存只是别丢东西，沿用它会让用户一边输入一边就把
   #      "调试完成"打掉了。
   #   2. 首次自动保存会**新建一行 scripts**：这是产品上认可的代价——否则"生成过但没保存"
   #      的内容没有归属，历史也无处可挂。配额校验已随计费体系移除，自动保存不再受限。
   #   3. 名称/描述是 NOT NULL，用占位兜底，等用户填写或 AI 命名后再覆盖。
   #   4. 与 /scripts/save 有字段重叠但**不合并**：两者对状态与标签的语义不同，合并会让
   #      "保存"这个动作的含义变成看参数而定，后面更难改。
   #   5. 草稿允许没有"支持的设备型号"：生成页是先生成代码、后填型号，首次自动保存常常发生在
   #      型号还空着的时候。型号的必填要求挪到了「调试完成」——型号参与脚本与设备的匹配，
   #      卡在"能不能被任务选中"这一关上（见 Script#validate_device_models）。
   def autosave
     return render json: { success: false, error: '请先登录' }, status: :unauthorized unless logged_in?

     script_uid = params[:script_uid].to_s.strip
     if script_uid.empty?
       return render json: { success: false, error: '缺少脚本标识（script_uid）' }, status: :unprocessable_entity
     end

     code = params[:code].to_s
     if code.strip.empty? || code.strip.start_with?(PLACEHOLDER_CODE_PREFIX)
       return render json: { success: false, error: '还没有可保存的脚本代码' }, status: :unprocessable_entity
     end

     script = current_user.scripts.find_by(script_uid: script_uid)
     device_models = parse_device_models_param(params[:device_models]) || (script && script.device_models) || []

     if script.nil?
       script = current_user.scripts.new(script_uid: script_uid, publish_status: :debugging)
     end

     source = autosave_source_param

     script.assign_attributes(
       name: params[:script_name].presence || script.name.presence || '未命名脚本',
       description: params[:script_description].presence || script.description.presence || '自动保存的草稿',
       initial_prompt: params[:initial_prompt].presence || script.initial_prompt || '',
       code: code,
       command_mapping: parse_command_mapping_param(params[:command_mapping]) || script.command_mapping || {},
       device_models: device_models,
       branch_scenarios: parse_branch_scenarios_param || script.branch_scenarios || [],
       # 版本号：重新生成涨 minor、微调涨 patch；普通自动保存不动（见 Script#next_version_for）
       version: script.next_version_for(source)
     )
     script.save!

     version = record_version(script, source)

     render json: {
       success: true,
       script_id: script.id,
       revision: version&.revision,
       version_id: version&.id,
       history_saved: version.present?,
       saved_at: Time.current.iso8601,
       script_status: script.publish_status,
       # 页面状态行显示它（版本号是用户关心的"这一版是哪一版"，revision 是快照序号）
       version: script.version
     }
   rescue ActiveRecord::RecordInvalid => e
     render json: { success: false, error: "自动保存失败：#{e.record.errors.full_messages.join('；')}" },
            status: :unprocessable_entity
   end

   # 版本历史列表
   # GET /scripts/versions?script_uid=xxx
   #
   # 只回摘要、不回代码：一次要渲染几十条，代码字段会让响应白白大出几十倍，
   # 需要看内容时再点进单条（/scripts/version）。
   def versions
     return render json: { success: false, error: '请先登录' }, status: :unauthorized unless logged_in?

     script = find_script_by_uid(params[:script_uid])
     return render json: { success: false, error: '脚本不存在或尚未保存' }, status: :not_found if script.nil?

     render json: {
       success: true,
       script_id: script.id,
       revision: script.revision,
       data: script.script_versions.recent.limit(VERSION_LIST_LIMIT).map { |v| version_summary_json(v) }
     }
   end

   # 单个版本详情（含代码与"与上一版的差异"，供"查看"与回滚前预览）
   # GET /scripts/version?script_uid=xxx&version_id=1
   def version
     return render json: { success: false, error: '请先登录' }, status: :unauthorized unless logged_in?

     script = find_script_by_uid(params[:script_uid])
     record = script && script.script_versions.find_by(id: params[:version_id])
     return render json: { success: false, error: '版本不存在' }, status: :not_found if record.nil?

     # 差异在服务端一次算好随详情返回：前端不必再拉一次上一版，也就不会出现"两个请求拿到
     # 不同时刻的数据"这种不一致（见 ScriptVersionDiff，首版返回 first: true）
     previous = script.script_versions.where('revision < ?', record.revision).order(revision: :desc).first

     render json: {
       success: true,
       current_revision: script.revision,
       data: version_detail_json(record),
       diff: ScriptVersionDiff.new(previous, record).to_h
     }
   end

   # 回滚到某个版本
   # POST /scripts/rollback
   #
   # 业务逻辑：把该版本的内容写回脚本，并**再记一条 source=rollback 的新版本**——
   # 回滚不改写历史，回滚本身也是一次内容变更，历史里要看得见。
   #
   # 隐性知识：回滚会把 publish_status 退回"未调试"（与手动保存一致）。当前这行脚本的
   # "调试完成"是针对被回滚掉的那份内容的；内容变了就必须重新认可，否则任务可能跑到一份
   # 没验证过的脚本上。
   def rollback
     return render json: { success: false, error: '请先登录' }, status: :unauthorized unless logged_in?

     script = find_script_by_uid(params[:script_uid])
     record = script && script.script_versions.find_by(id: params[:version_id])
     return render json: { success: false, error: '版本不存在' }, status: :not_found if record.nil?

     script.assign_attributes(
       name: record.name,
       description: record.description,
       code: record.code,
       # 主线描述也要还原：否则页面会呈现"旧代码 + 新需求"的组合，最容易误导人
       initial_prompt: record.initial_prompt.to_s,
       command_mapping: record.command_mapping || {},
       device_models: record.device_models || [],
       branch_scenarios: record.branch_scenarios || [],
       publish_status: :debugging
     )
     script.save!
     restored = record_version(script, 'rollback')

     render json: {
       success: true,
       message: "已回滚到 r#{record.revision}",
       revision: restored&.revision,
       history_saved: restored.present?,
       rolled_back_from: record.revision,
       # 版本写入失败时也要把内容回给页面：页面靠 data 刷新编辑器，不能因为历史没记上就白回滚
       data: version_detail_json(restored || record)
     }
   rescue ActiveRecord::RecordInvalid => e
     render json: { success: false, error: "回滚失败：#{e.record.errors.full_messages.join('；')}" },
            status: :unprocessable_entity
   end

   # 自动化生成脚本（生成→测试→评估→重试）
  # POST /scripts/auto_generate
  # 参数：{ description: "自然语言描述"}
  # 返回：流式 SSE 事件，实时反馈进度
  def auto_generate
    body = parsed_json_body
    description = params[:description].presence || body['description']
    branches = normalize_branch_params(body['branches'])

    if description.nil?
      return render json: { error: '描述不能为空' }, status: :unprocessable_entity unless request.headers['Accept']&.include?('text/event-stream')
      # 如果是 SSE 请求，发送错误事件
      response.headers['Content-Type'] = 'text/event-stream'
      response.stream.write("event: error\ndata: #{ { error: '描述不能为空' }.to_json }\n\n")
      response.stream.write("event: done\ndata: {}\n\n")
      response.stream.close
      return
    end

    # 配额检查已移除。
    #
    # 隐性知识（这里踩过坑）：脚本生成在 BYOK 模式下用的是**用户自己的 LLM Key**，
    # 平台不再为这次生成付任何费用，因此不该再用「本月 AI 生成次数」卡用户。
    # 早先只下掉了前端的信用点展示，服务端这段校验还在，用户跑到 20/20 时会拿到
    # 429 quota_exceeded，且因为是普通 JSON 响应、前端只能把原始 JSON 甩到界面上。
    # 设置 SSE 响应头
    response.headers['Content-Type'] = 'text/event-stream'
    response.headers['Cache-Control'] = 'no-cache'
    response.headers['Connection'] = 'keep-alive'
    response.headers['X-Accel-Buffering'] = 'no'

    # base_code 存在时为"微调"：在现有代码基础上按当前描述做最小改动
    base_code = body['base_code'].presence
    script_uid = body['script_uid'].presence || params[:script_uid].presence
    service = AutoGenerateService.new(description, branches: branches, user: current_user,
                                                    base_code: base_code, script_uid: script_uid)

    result = service.call do |progress|
      send_sse_event(progress[:stage], progress.except(:stage))
    end

    # 不再累加 ai_generations 用量：BYOK 下这次生成花的是用户自己的额度，
    # 平台的计数器对它没有意义（继续累加只会让一个不再被校验的数字一直涨）。
    # 发送最终结果
    send_sse_event(:complete, result)



   rescue LlmApiKey::MissingApiKeyError => e
     # 必须显式捕获：该异常刻意继承自 Exception（不被裸 rescue 吞掉），
     # 若不在这里处理就会逃到 rescue_from 去 render json，而本响应已经是 SSE，
     # 客户端会收到格式不符的内容、难以给出有意义的提示。
     send_sse_event(:error, { error: e.message, code: 'missing_llm_api_key' })
   rescue => e
     # 擦除 Key：异常消息可能间接带出凭据（如 NoMethodError 会打印字符串接收者），
     # 而这里的内容会直接回给浏览器。
     send_sse_event(:error, { error: redact_llm_key(e.message), backtrace: e.backtrace&.first(5) })
   ensure
     # 发送结束标记
     response.stream.write("event: done\ndata: {}\n\n")
     response.stream.close
   end
  
  

  # AI 建议分支场景
  # POST /scripts/suggest_branches
  # 参数：{ description: "主线描述", branches: [{name, description}, ...],
  #         custom_requirement: "用户指定的分支场景（可选）" }
  # 返回：{ success: true, branches: [{name, description}, ...] }
  #       （默认最多 3 条；带 custom_requirement 时按用户描述生成 1~5 条）
  def suggest_branches
    body = parsed_json_body
    description = params[:description].presence || body['description']

    if description.blank?
      return render json: { success: false, error: '主线描述不能为空' }, status: :unprocessable_entity
    end

    branches = normalize_branch_params(body['branches'])
    avoid_branches = normalize_branch_params(body['avoid'])
    result = BranchSuggestionService.new(
      description,
      existing_branches: branches,
      avoid_branches: avoid_branches,
      custom_requirement: normalize_custom_requirement(body['custom_requirement']),
      user: current_user
    ).call

    if result[:success]
      render json: {
        success: true,
        branches: result[:branches],
        dropped: result[:dropped] || [],
        consistency_checked: result[:consistency_checked] != false
      }
    else
      render json: {
        success: false,
        error: result[:error],
        dropped: result[:dropped] || [],
        consistency_checked: result[:consistency_checked] == true
      }, status: :unprocessable_entity
    end
  end

  # 单个场景「运行」：按该场景描述只生成命令映射，再用**当前脚本代码**跑一遍并评估。
  #
  # POST /scripts/run_scenario
  # 参数：{ code, kind: 'main'|'branch', name, description, mainline_description, script_uid }
  # 返回：{ success: true, kind, name, description, command_mapping, test_result, evaluation, passed }
  #
  # 隐性知识：
  #   1. **绝不重新生成或修改脚本代码**：code 原样进映射生成与 DebugSession，服务本身也只产映射
  #      （见 BranchMappingGenerationService / Prompts::BranchMapping）。
  #   2. 与 auto_generate 的差异：不重试、不判定整体成败，只跑用户点名的这一个场景。
  #   3. 分支要带上主线描述作背景，帮助模型理解代码；主线场景则不需要（它就是主线）。
  def run_scenario
    body = parsed_json_body
    code = (params[:code].presence || body['code']).to_s
    description = (params[:description].presence || body['description']).to_s.strip
    kind = (params[:kind].presence || body['kind']).to_s == 'main' ? 'main' : 'branch'
    name = (params[:name].presence || body['name']).to_s
    mainline_description = (params[:mainline_description].presence || body['mainline_description']).to_s

    if code.strip.empty?
      return render json: { success: false, error: '请先生成脚本代码' }, status: :unprocessable_entity
    end
    if description.empty?
      return render json: { success: false, error: '场景描述不能为空' }, status: :unprocessable_entity
    end

    mapping_result = BranchMappingGenerationService.new(
      code,
      description,
      mainline_description: kind == 'main' ? nil : mainline_description,
      user: current_user,
      scenario_kind: kind == 'main' ? :main : :branch
    ).call

    if mapping_result[:error].present?
      return render json: { success: false, error: "命令映射生成失败：#{mapping_result[:error]}" },
                    status: :unprocessable_entity
    end

    command_mapping = mapping_result[:command_mapping]
    test_result = DebugSession.new(code, description, command_mapping, 0, user: current_user).run
    evaluation = ScriptEvaluationService.new(description, code, command_mapping, test_result).call

    render json: {
      success: true,
      kind: kind,
      name: name,
      description: description,
      command_mapping: command_mapping,
      test_result: test_result,
      evaluation: evaluation,
      passed: evaluation[:passed] == true
    }
  rescue => e
    Rails.logger.error("[ScriptsController#run_scenario] #{e.class}: #{redact_llm_key(e.message)}")
    render json: { success: false, error: redact_llm_key(e.message) }, status: :unprocessable_entity
  end

  # 检查分支与主线是否一致（矛盾 / 超纲）
  # POST /scripts/check_branches
  # 参数：{ description: "主线描述", branches: [{name, description}, ...] }
  # 返回：{ success: true, results: [{index, name, verdict, reason, offending}], has_issues: Boolean }
  def check_branches
    body = parsed_json_body
    description = params[:description].presence || body['description']

    if description.blank?
      return render json: { success: false, error: '主线描述不能为空' }, status: :unprocessable_entity
    end

    branches = normalize_branch_params(body['branches'])
    if branches.empty?
      return render json: { success: false, error: '请先填写至少一个分支' }, status: :unprocessable_entity
    end

    result = BranchConsistencyService.new(description, branches).call
    if result[:success]
      render json: { success: true, results: result[:results], has_issues: result[:has_issues] }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_entity
    end
  end

  # 根据用户目标与手工操作日志生成需求描述框架
  # POST /scripts/draft_requirement
  # 参数：{ goal: "目标", log: "手工操作日志" }
  # 返回：{ success: true, description: "含【待确认#N】占位的框架",
  #         open_questions: [{id, question, options}], notes: [] }
  def draft_requirement
    body = parsed_json_body
    goal = params[:goal].presence || body['goal']
    log = params[:log].presence || body['log']

    result = ScriptRequirementDraftService.new(goal, log, user: current_user).call

    if result[:success]
      render json: {
        success: true,
        description: result[:description],
        open_questions: result[:open_questions],
        notes: result[:notes]
      }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_entity
    end
  end

  # 按「客户端真实执行日志 + 用户要求」改进主线描述
  # POST /scripts/improve_description
  #
  # 入参（JSON）：description 当前主线描述（可为空）、requirement 用户要求、
  #              log 客户端日志（可为空）、checkpoints 检查点结论、error 脚本错误
  #
  # 隐性知识：
  #   1. 这里**不落任何东西**：日志与描述只进 LLM 请求，出来就是内存里的字符串，
  #      由用户预览后决定要不要应用。参数过滤见 initializer 与 BaseController。
  #   2. 权限：开源版免登录，任何访问都可用（以本地操作员身份运行）。
  def improve_description
    body = parsed_json_body

    result = ScriptDescriptionImprovementService.new(
      description: body['description'],
      requirement: params[:requirement].presence || body['requirement'],
      log: params[:log].presence || body['log'],
      checkpoints: body['checkpoints'],
      error: body['error'],
      user: current_user
    ).call

    if result[:success]
      render json: {
        success: true,
        description: result[:description],
        open_questions: result[:open_questions],
        notes: result[:notes]
      }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_entity
    end
  end

   private

  # 首页 Hero 交过来的目标与日志（POST 正文，不落任何存储）
  #
  # 隐性知识：只认 POST —— 目标与日志加起来可达 4 万字，放 URL 会撑爆请求行；而按用户要求
  # 也不能落在浏览器（sessionStorage / localStorage）或 cookie/session（4KB 上限）里。
  # 所以走"表单 POST + 服务端这一次渲染注入"：刷新即为空表单，需要就回首页重新触发。
  #
  # 不做截断：宁可原样带过来，让页面上的字数计数如实显示"超了"，由用户自己删减
  # （与页内那个入口的约定一致）；只有明显异常的请求体才整体忽略。
  def draft_prefill_from_params
    return nil unless request.post?

    goal = params[:draft_goal].to_s
    log = params[:draft_log].to_s
    return nil if goal.strip.empty? && log.strip.empty?
    return nil if goal.bytesize > 10_000 || log.bytesize > 1_000_000

    { goal: goal, log: log }
  end

  # 解析 JSON 请求体（非 JSON 请求返回空哈希）
  def parsed_json_body
    return {} unless request.post?
    return {} unless request.content_type&.include?('application/json')

    request.body.rewind
    parsed = JSON.parse(request.body.read)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # 规范化分支参数：只保留有描述的项，兼容 symbol/string 键
  def normalize_branch_params(raw)
    return [] unless raw.is_a?(Array)

    raw.map do |branch|
      next unless branch.respond_to?(:[])

      name = (branch[:name] || branch['name']).to_s.strip
      description = (branch[:description] || branch['description']).to_s.strip
      next if description.empty?

      { name: name, description: description }
    end.compact
  end

  # 用户自定义场景的描述：去空白并做长度保护。
  #
  # 隐性知识：这段文本会原样进提示词，超长会显著抬高 token 成本；这里设上限截断，
  # 与页面上其他"长文本摘要"的做法一致（用户仍可在描述里写多个场景）。
  def normalize_custom_requirement(raw)
    text = raw.to_s.strip
    return nil if text.empty?

    text[0, MAX_CUSTOM_REQUIREMENT_LENGTH]
  end

  # 解析页面提交的分支场景 JSON；非法时返回 nil（保留脚本原有的分支数据）
  def parse_branch_scenarios_param
    raw = params[:branch_scenarios]
    return nil if raw.blank?

    parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
    parsed.is_a?(Array) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  # 写一条版本快照。
  #
  # 隐性知识：**历史写失败不该让内容保存失败**。自动保存的首要是"别丢东西"，而版本快照是
  # 附加价值——实测过一次：script_versions 表还没建（迁移没跑）时，脚本内容已经存进去了，
  # 却因为写版本抛 PG::UndefinedTable 把整个请求变成 500，用户看到的是"自动保存失败"，
  # 实际上内容已经落库。所以这里兜住异常、记 warning，把结果告诉调用方（history_saved）。
  def record_version(script, source)
    ScriptVersionRecorder.record(script, source: source, user: current_user)
  rescue StandardError => e
    hint = schema_drift_hint(e)
    Rails.logger.warn("[ScriptsController] 版本快照写入失败（内容已保存）：#{e.class}: #{e.message}#{hint}")
    nil
  end

  # 判断这次失败是不是"服务端没重启、schema 缓存过期"。
  #
  # 隐性知识：实测两种表现都出现过——加列后是 UnknownAttributeError（缓存里没有新列），
  # 早先是 NoMethodError: undefined method 'revision'（缓存里没有该属性）；表不存在则是
  # StatementInvalid。把这个判断写进日志，下次不用再从"内容存了但历史没记"倒查。
  def schema_drift_hint(error)
    drift = case error
            when ActiveModel::UnknownAttributeError then true
            when ActiveRecord::StatementInvalid then error.message.include?('does not exist')
            when NoMethodError then error.message.include?('revision') || error.message.include?('initial_prompt')
            else false
            end

    drift ? '（疑似服务端在迁移后未重启，schema 缓存过期；重启后可正常记版本）' : ''
  end

  # 按 script_uid 在当前用户范围内定位脚本（历史相关动作共用）。
  # 一律走 current_user.scripts，越权访问别人的 uid 自然就是"不存在"。
  def find_script_by_uid(raw_uid)
    uid = raw_uid.to_s.strip
    return nil if uid.empty?

    current_user.scripts.find_by(script_uid: uid)
  end

  # URL 带来的 uid 是否可以沿用（见 index 里的说明）：格式合法，且没有被任何脚本占用。
  def adoptable_uid_param
    uid = params[:script_uid].to_s.strip
    return nil unless uid.match?(/\A[0-9a-f]{16}\z/)
    return nil if Script.exists?(script_uid: uid)

    uid
  end

  # 自动保存的来源：只认生成与微调，其余（含伪造的手动保存/回滚）都归为自动保存——
  # 手动保存、调试完成、回滚各有自己的动作，不该由前端传参决定历史里怎么写。
  def autosave_source_param
    source = params[:source].to_s
    %w[generated refined].include?(source) ? source : 'autosave'
  end

  def version_summary_json(version)
    {
      id: version.id,
      revision: version.revision,
      source: version.source,
      source_label: version.source_label,
      name: version.name,
      # 列表第二行用它：让每条版本一眼看出"要做什么"，而不是只看到名称或代码
      initial_prompt_excerpt: excerpt_of(version.initial_prompt),
      created_at: version.created_at.iso8601,
      # 描述没变时新内容只刷新当前版本，所以"最后更新"往往晚于"建立"——两个都给出来，
      # 用户才能对上"这条版本后来又被改过"
      updated_at: version.updated_at.iso8601
    }
  end

  # 主线描述摘要：压成一行再截断（原文里的换行会让列表项高度参差）
  def excerpt_of(text)
    plain = text.to_s.gsub(/\s+/, ' ').strip
    return plain if plain.length <= VERSION_EXCERPT_LENGTH

    "#{plain[0, VERSION_EXCERPT_LENGTH]}…"
  end

  def version_detail_json(version)
    version_summary_json(version).merge(
      description: version.description,
      code: version.code,
      initial_prompt: version.initial_prompt,
      publish_status: version.publish_status,
      command_mapping: version.command_mapping,
      device_models: version.device_models,
      branch_scenarios: version.branch_scenarios
    )
  end

  # 命令映射参数：非法 JSON 返回 nil（调用方会退回脚本里已有的映射，不覆盖成空）
  def parse_command_mapping_param(raw)
    return nil if raw.blank?

    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end

  # 设备型号参数："a, b" → ["a", "b"]
  def parse_device_models_param(raw)
    return nil if raw.blank?

    raw.to_s.split(',').map(&:strip).reject(&:empty?)
  end

  # 发送 SSE 事件
  def send_sse_event(event_type, data)
    Rails.logger.error "[ERROR] ScriptsController - send_sse_event: event_type=#{event_type}, data keys=#{data.keys if data.respond_to?(:keys)}"

    # 对于 generated 事件，特别记录代码和映射信息
    if event_type == :generated
      Rails.logger.error "[ERROR] ScriptsController - generated 事件数据:"
      Rails.logger.error "[ERROR] ScriptsController - code 是否存在: #{data.key?(:code)}"
      Rails.logger.error "[ERROR] ScriptsController - code 长度: #{data[:code].to_s.length}"
      Rails.logger.error "[ERROR] ScriptsController - command_mapping 是否存在: #{data.key?(:command_mapping)}"
      Rails.logger.error "[ERROR] ScriptsController - command_mapping 类型: #{data[:command_mapping].class if data[:command_mapping]}"
      Rails.logger.error "[ERROR] ScriptsController - command_mapping 数量: #{data[:command_mapping].length if data[:command_mapping].respond_to?(:length)}"
    end

    response.stream.write("event: #{event_type}\n")
    response.stream.write("data: #{data.to_json}\n\n")
  end
  
  
end
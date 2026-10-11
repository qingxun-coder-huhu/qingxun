# frozen_string_literal: true

require_relative 'script_generation_service'
require_relative 'generation_request_context'
require_relative 'branch_mapping_generation_service'
require_relative 'debug_session'
require_relative 'script_evaluation_service'
require_relative 'llm_request_service'
require_relative 'prompts'

# AutoGenerateService 负责完整的自动化脚本生成流程。
#
# 业务逻辑：
#   - 接收用户需求描述（主线）
#   - 调用 AI 生成脚本（ScriptGenerationService）——**只依据主线描述生成一份代码**
#   - 为每个分支场景用 BranchMappingGenerationService 生成该场景的命令-报文映射
#   - 对主线与每个分支分别执行沙盒测试（DebugSession）
#   - 对每个场景分别调用 AI 评估（ScriptEvaluationService）
#   - **主线与全部分支都通过，整体才算通过**
#   - 未通过时，把各场景的失败点与改进建议汇入下一轮生成；最多尝试 3 次
#
# 隐性知识：
#   - 分支描述不进入代码生成提示词（一份代码只按主线生成），但分支的失败反馈会回流，
#     用来指导重新生成同一份代码。
#   - 每次重试时，需要将之前的错误信息和改进建议传递给生成服务
#   - 评估结果包含具体的改进方向，可以指导下一轮生成
#   - 3 次失败后的建议应该具体、可操作，帮助用户理解问题所在
#   - 各场景的「命令映射粘性补充」状态按场景 key 分桶，避免不同分支的映射要求互相串味
class AutoGenerateService
  MAX_ATTEMPTS = 3

  # 主线场景的分桶 key
  MAIN_KEY = 'main'

  # 初始化自动化生成服务。
  # 参数：
  #   description: 用户原始需求描述（主线）
  #   branches: 分支场景数组 [{ name:, description: }, ...]，只填全量描述
  #   user: 当前用户（可选），用于获取自定义集成信息
  #   base_code: 现有脚本代码（可选）。提供时进入"微调"模式：在其基础上按当前描述做最小改动
  #   script_uid: 脚本唯一标识（可选）。页面初始化时确定，作为生成类名的稳定后缀
  def initialize(description, branches: [], user: nil, base_code: nil, script_uid: nil)
    @description = description.to_s.strip
    raise ArgumentError, '描述不能为空' if @description.empty?
    @branches = normalize_branches(branches)
    @user = user
    @base_code = base_code.to_s.strip.presence
    @script_uid = script_uid.to_s.strip.presence
    @attempt_history = []
    # 评估确认"必须有映射"的命令（command => 建议）。**只增不减**：一旦某命令被判定
    # 需要映射，后续每一轮都要继续要求保留，否则重新生成映射时会被丢掉。
    # 按场景 key 分桶：主线与各分支互不影响。
    @required_mappings = Hash.new { |h, k| h[k] = {} }
    # 各场景当前这轮生成的映射里实际包含的命令
    @latest_mapping_commands = Hash.new { |h, k| h[k] = [] }
    # 各场景已确认补齐的命令映射（供报告披露：我们动过测试环境）
    @mapping_supplements = Hash.new { |h, k| h[k] = [] }
    # 各场景仍缺失的命令映射（由 required - latest 推导）
    @pending_mapping_suggestions = {}
    # 需要用户确认的问题（脚本/平台都拿不到的信息）。只增不减、去重。
    @user_questions = []
    # 最近一次完成尝试的生成结果与场景结果（失败时用于回填最终产物）
    @last_generation = nil
    @last_scenario_results = []
  end

  # 执行自动化生成流程。
  # 支持块回调，用于实时反馈进度。
  # 返回哈希 {
  #   success: Boolean,           # 是否成功（全部场景通过）
  #   code: String,               # 生成的脚本代码
  #   command_mapping: Array,     # 主线命令映射（兼容旧调用方）
  #   test_result: Hash,          # 主线测试执行结果
  #   evaluation: Hash,           # 主线最终评估结果
  #   scenarios: Array,           # 各场景（主线+分支）的完整结果
  #   branch_scenarios: Array,    # 分支场景（供前端持久化）
  #   attempts: Integer,          # 尝试次数
  #   history: Array,             # 每次尝试的历史记录
  #   final_suggestion: String    # 如果失败，AI 给出的下一步建议
  # }
  def call(&progress_callback)
    # 获取或创建用户请求记录（如果有关联用户）
    user_request = get_or_create_user_request
    if user_request
      # 设置当前请求上下文
      set_request_context(user_request.request_id)
      # 标记请求为处理中
      user_request.mark_processing!
    end

    attempt = 0
    error_history = ""

    while attempt < MAX_ATTEMPTS
      attempt += 1
      report_progress(progress_callback, :start_attempt, attempt: attempt, max: MAX_ATTEMPTS)

      # 步骤1：生成脚本（只用主线描述）
      report_progress(progress_callback, :generating, attempt: attempt)
      generation_result = generate_script(error_history)
      @last_generation = generation_result

      if generation_result[:error]
        record_attempt(attempt, :generation_failed, generation_result)
        error_history = generation_result[:error]
        report_progress(progress_callback, :generation_failed, error: generation_result[:error])
        next
      end

      # 记录主线映射实际包含的命令；上一轮要求保留的映射若这次带上来了，记为"已补齐"
      reconcile_mapping_supplements(MAIN_KEY, generation_result[:command_mapping], attempt)

      report_progress(progress_callback, :generated,
        code: generation_result[:code],
        command_mapping: generation_result[:command_mapping],
        script_name: generation_result[:script_name],
        description: generation_result[:description]
      )

      # 步骤2：只测试与评估主线——主线是唯一的通过判定依据
      main_result = run_scenario(main_scenario(generation_result), progress_callback)
      main_results = [main_result]
      @last_scenario_results = main_results

      record_attempt(attempt, :completed, {
        generation: generation_result,
        scenarios: main_results
      })

      # 收集"需要用户确认"的问题与映射补充建议（只看主线）
      collect_user_questions_and_suggestions(main_results, attempt)

      # 主线通过即成功；分支不参与通过判定
      if main_result[:passed]
        report_progress(progress_callback, :success,
          attempt: attempt,
          mapping_supplements: all_mapping_supplements,
          mapping_supplement_notice: mapping_supplement_notice
        )

        # 主线通过后才执行分支：分支结果只用于告知用户，不回流、不影响成功判定
        branch_results = run_branches(generation_result[:code], progress_callback)
        all_results = main_results + branch_results
        @last_scenario_results = all_results

        if user_request
          success_result = {
            attempt_count: attempt,
            script_name: generation_result[:script_name],
            code_length: generation_result[:code].length,
            command_mapping_count: CommandMappingParser.flatten(generation_result[:command_mapping]).size,
            scenario_count: all_results.size,
            branch_count: branch_results.size,
            branch_passed_count: branch_results.count { |b| b[:passed] },
            evaluation_passed: true,
            mapping_supplement_count: all_mapping_supplements.size
          }
          user_request.mark_completed!(success_result)
        end
        return build_success_result(generation_result, main_result, branch_results, attempt)
      end

      # 若剩下的失败项都不是脚本能修的（只等用户提供信息），继续重试只是空转——
      # 直接把问题回抛给用户，让他们确认后再继续。
      if needs_user_confirmation_only?(main_results)
        report_progress(progress_callback, :needs_clarification, questions: @user_questions)
        if user_request
          user_request.mark_failed!("需要用户确认：#{@user_questions.join('；')}")
        end
        return build_clarification_result(generation_result, main_results, attempt)
      end

      error_history = build_error_history(main_results)
      report_progress(progress_callback, :retry,
        attempt: attempt,
        issues: aggregate_issues(main_results),
        suggestions: aggregate_suggestions(main_results)
      )
    end

    # 3 次尝试均失败，获取 AI 建议
    report_progress(progress_callback, :final_failed, attempts: MAX_ATTEMPTS)
    final_suggestion = get_final_suggestion

    # 标记请求为失败（如果存在）
    if user_request
      error_message = "自动化生成失败，尝试 #{MAX_ATTEMPTS} 次后未通过评估。"
      user_request.mark_failed!(error_message)
    end

    build_failure_result(final_suggestion, attempt)
  end

  private

  # 规范化分支参数，丢弃空描述，并为缺省名称补「分支N」
  def normalize_branches(branches)
    normalized = Array(branches).map do |branch|
      next unless branch.respond_to?(:[])
      description = (branch[:description] || branch['description']).to_s.strip
      next if description.empty?

      name = (branch[:name] || branch['name']).to_s.strip
      { name: name, description: description }
    end.compact

    normalized.each_with_index do |branch, index|
      branch[:name] = "分支#{index + 1}" if branch[:name].empty?
    end
    normalized
  end

  def branch_key(index)
    "branch:#{index}"
  end

  def scenario_meta(key, kind, name)
    { key: key, kind: kind.to_s, name: name }
  end

  # 主线场景：唯一参与通过判定的场景
  def main_scenario(generation_result)
    {
      key: MAIN_KEY,
      kind: :main,
      name: '主线',
      description: @description,
      code: generation_result[:code],
      command_mapping: generation_result[:command_mapping],
      mapping_error: nil
    }
  end

  # 主线通过后执行分支：生成各分支命令映射并逐个测试/评估。
  # 分支结果只用于向用户告知，不参与通过判定，也不回流到下一轮生成。
  def run_branches(code, progress_callback)
    return [] if @branches.empty?

    @branches.each_with_index.map do |branch, index|
      key = branch_key(index)
      meta = scenario_meta(key, :branch, branch[:name])
      report_progress(progress_callback, :scenario_mapping_generating, scenario: meta)

      mapping_result = BranchMappingGenerationService.new(
        code,
        branch[:description],
        mainline_description: @description,
        user: @user
      ).call

      # 把该分支的命令映射尽早推给前端，便于切换标签时同步展示
      report_progress(progress_callback, :scenario_mapping_generated,
        scenario: meta,
        command_mapping: mapping_result[:command_mapping],
        error: mapping_result[:error]
      )

      run_scenario({
        key: key,
        kind: :branch,
        name: branch[:name],
        description: branch[:description],
        code: code,
        command_mapping: mapping_result[:command_mapping],
        mapping_error: mapping_result[:error]
      }, progress_callback)
    end
  end

  # 对单个场景执行沙盒测试 + 评估
  def run_scenario(scenario, progress_callback)
    meta = scenario_meta(scenario[:key], scenario[:kind], scenario[:name])
    main = scenario[:kind] == :main

    report_progress(progress_callback, :testing, attempt: nil) if main
    report_progress(progress_callback, :scenario_testing, scenario: meta)

    test_result = if scenario[:mapping_error]
                    { success: false, error: "分支命令映射生成失败: #{scenario[:mapping_error]}", logs: [] }
                  else
                    run_test(scenario[:code], scenario[:description], scenario[:command_mapping])
                  end

    report_progress(progress_callback, :tested, result: test_result) if main
    report_progress(progress_callback, :scenario_tested, scenario: meta, result: test_result)

    report_progress(progress_callback, :evaluating, scenario: meta)
    evaluation = if scenario[:mapping_error]
                   mapping_error_failure(scenario[:mapping_error])
                 else
                   evaluate_result(scenario[:description], scenario[:code], scenario[:command_mapping], test_result)
                 end

    report_progress(progress_callback, :evaluated, result: evaluation) if main
    report_progress(progress_callback, :scenario_evaluated, scenario: meta, result: evaluation)

    scenario.merge(test_result: test_result, evaluation: evaluation, passed: evaluation[:passed] == true)
  end

  # 分支映射生成失败时，构造一个明确的失败评估，保证页面能看到原因
  def mapping_error_failure(message)
    {
      passed: false,
      evaluation: "分支命令映射生成失败，无法完成该场景测试：#{message}",
      suggestions: ['请调整该分支描述后重新生成'],
      issues: ["分支命令映射生成失败：#{message}"],
      items: [],
      env_mismatches: [],
      user_questions: [],
      mapping_suggestions: []
    }
  end

  # 请求上下文（开源版不再落库记录，见 GenerationRequestContext）
  def get_or_create_user_request
    GenerationRequestContext.current
  end

  # 设置当前请求上下文
  def set_request_context(request_id)
    Thread.current[:user_request_context] ||= {}
    Thread.current[:user_request_context][:request_id] = request_id
  end

  # 报告进度（如果提供了回调块）
  def report_progress(callback, stage, **data)
    return unless callback
    callback.call({ stage: stage, timestamp: Time.now }.merge(data))
  end

  # 记录尝试历史
  def record_attempt(attempt_number, status, data)
    @attempt_history << {
      attempt: attempt_number,
      status: status,
      data: data,
      timestamp: Time.now
    }
  end

  # 生成脚本（普通模式只依据主线描述；微调模式在现有代码基础上按当前描述做最小改动）
  def generate_script(error_history = "")
    service = if @base_code
                ScriptGenerationService.new(
                  @description,
                  feedback: error_history.presence,
                  user: @user,
                  existing_code: @base_code,
                  branches: @branches,
                  script_uid: @script_uid
                )
              else
                ScriptGenerationService.new(@description, feedback: error_history.presence,
                                                          user: @user, script_uid: @script_uid)
              end
    result = service.call

    {
      code: result[:code],
      command_mapping: result[:command_mapping],
      script_name: result[:script_name],
      description: result[:description]
    }
  rescue => e
    Rails.logger.error "[AutoGenerateService] generate_script 出错: #{e.message}"
    { error: e.message, backtrace: e.backtrace&.first(5) }
  end

  # 执行沙盒测试
  def run_test(code, description, command_mapping)
    session = DebugSession.new(code, description, command_mapping, 0, user: @user)
    session.run
  rescue => e
    { success: false, error: e.message, logs: [] }
  end

  # 评估测试结果
  def evaluate_result(description, code, command_mapping, test_result)
    service = ScriptEvaluationService.new(description, code, command_mapping, test_result)
    service.call
  end

  # 汇总所有场景未达成的需求条目（带场景标签）
  def all_failed_items(scenario_results)
    Array(scenario_results).flat_map do |scenario|
      Array(scenario[:evaluation][:items]).reject { |item| item[:passed] }.map do |item|
        item.merge(scenario_name: scenario[:name], scenario_kind: scenario[:kind].to_s)
      end
    end
  end

  def aggregate_issues(scenario_results)
    Array(scenario_results).flat_map { |s| Array(s[:evaluation][:issues]) }.uniq
  end

  def aggregate_suggestions(scenario_results)
    Array(scenario_results).flat_map { |s| Array(s[:evaluation][:suggestions]) }.uniq
  end

  # 构建错误历史，供下次生成参考
  #
  # 隐性知识：这里必须按**条目**回流，而不是把 issues/suggestions 拼成一坨散文。
  # 只有"需求第 N 条：期望 X、实际 Y、证据 Z（归因）"这种粒度，下一轮生成才能
  # 精准地只改没过的那条；否则模型只能对着一段笼统描述反复猜。
  # 分支场景的失败也要回流——代码只按主线生成，但必须修到能通过所有分支。
  def build_error_history(scenario_results)
    parts = []

    Array(scenario_results).each do |scenario|
      main = scenario[:kind] == :main
      label = main ? '主线' : "分支：#{scenario[:name]}"

      if main
        parts << "评估未通过: #{scenario[:evaluation][:evaluation]}"
      else
        parts << "=== 分支场景【#{scenario[:name]}】评估未通过 ==="
        parts << scenario[:evaluation][:evaluation].to_s
      end

      failed_items = Array(scenario[:evaluation][:items]).reject { |it| it[:passed] }
      if failed_items.any?
        parts << "未达成的需求条目（请逐条修正，不要改动已通过的条目）:"
        failed_items.each_with_index do |item, idx|
          line = "#{idx + 1}. #{item[:requirement]}"
          line += "｜期望: #{item[:expected]}" if item[:expected].present?
          line += "｜实际: #{item[:observed]}" if item[:observed].present?
          line += "｜证据: #{item[:evidence]}" if item[:evidence].present?
          line += "｜归因: #{item[:attribution]}" if item[:attribution].present?
          line += "｜说明: #{item[:note]}" if item[:note].present?
          parts << line
        end
      end

      env_mismatches = Array(scenario[:evaluation][:env_mismatches])
      if env_mismatches.any?
        parts << "测试环境/映射问题（不要靠改脚本去迁就，应修正命令映射）: #{env_mismatches.join('; ')}"
      end

      # 已确认"必须有映射"的命令要**每轮都要求保留**（粘性）。
      required = @required_mappings[scenario[:key]]
      if required.any?
        parts << "以下命令必须出现在本次生成的命令映射中（已有的务必保留，缺失的按建议报文补齐；" \
                 "这是补测试环境，不是改脚本逻辑去适配错误回显）:"
        required.each do |command, suggestion|
          status = @latest_mapping_commands[scenario[:key]].include?(command) ? '已存在，必须保留' : '缺失，需补齐'
          parts << "  - #{command}（#{status}）｜建议报文: #{suggestion[:suggested_response].inspect}｜" \
                   "依据: #{suggestion[:reason]}"
        end
      end

      issues = Array(scenario[:evaluation][:issues])
      parts << "发现的问题: #{issues.join('; ')}" if issues.any?
      suggestions = Array(scenario[:evaluation][:suggestions])
      parts << "改进建议: #{suggestions.join('; ')}" if suggestions.any?
      if scenario[:test_result] && scenario[:test_result][:error]
        parts << "测试错误: #{scenario[:test_result][:error]}"
      end
    end

    parts.join("\n")
  end

  # 收集本轮评估确认"必须有映射"的命令。**只增不减**：已确认过的命令永久保留，
  # 这样后续每一轮都会继续要求生成侧保留它。
  def collect_mapping_suggestions(key, evaluation_result, attempt = nil)
    Array(evaluation_result[:mapping_suggestions]).each do |suggestion|
      command = suggestion[:command].to_s
      next if command.empty?

      @required_mappings[key][command] ||= suggestion.merge(first_required_attempt: attempt)
    end
    refresh_pending_mappings(key)
  end

  # 记录本轮生成实际包含的映射命令，并核算哪些要求项已补齐、哪些仍缺
  def reconcile_mapping_supplements(key, mapping, attempt = nil)
    # 映射可能是嵌套的上下文树，必须摊平后再核算，否则子树里的命令会被误判成"仍缺失"
    entries = CommandMappingParser.flatten(mapping)
    @latest_mapping_commands[key] = mapping_commands_of(mapping)

    @required_mappings[key].each do |command, suggestion|
      next unless @latest_mapping_commands[key].include?(command)
      next if @mapping_supplements[key].any? { |m| m[:command] == command }

      actual = entries.find { |m| m[:command].to_s == command }
      @mapping_supplements[key] << suggestion.merge(
        actual_response: (actual && actual[:response]).to_s,
        supplemented_at_attempt: attempt
      )
    end

    refresh_pending_mappings(key)
  end

  # 仍然缺失的命令映射 = 要求项 - 当前映射
  def refresh_pending_mappings(key)
    @pending_mapping_suggestions[key] =
      @required_mappings[key].values.reject { |s| @latest_mapping_commands[key].include?(s[:command]) }
  end

  def pending_mapping_suggestions
    @pending_mapping_suggestions.values.flatten
  end

  # 映射里出现过的全部命令（含嵌套子树里的命令）
  def mapping_commands_of(mapping)
    CommandMappingParser.flatten(mapping).map { |m| m[:command].to_s }.reject(&:empty?)
  end

  # 收集"需要用户确认"的问题（去重）
  #
  # 隐性知识：这类问题脚本和平台都无解（例如网元名称的来源），让模型继续重试只会
  # 逼它编一个值。正确做法是把问题回抛给用户。
  #
  # 另一个实测坑：模型会一边把失败归因成 script_issue/env_mismatch，一边又抛出一堆
  # "需要确认"的问题（其中不少是需求描述里已经写明、或本次描述范围之外的）。
  # 因此这里只在**确实存在 needs_user_confirmation 条目**时才采纳它的问题；
  # 同时每轮重置，避免上一轮已解决的疑问继续挂在结果里让用户确认。
  def collect_user_questions_and_suggestions(scenario_results, attempt)
    @user_questions = []

    Array(scenario_results).each do |scenario|
      evaluation_result = scenario[:evaluation]
      needs_confirmation = Array(evaluation_result[:items]).any? do |item|
        item[:attribution].to_s == 'needs_user_confirmation'
      end

      if needs_confirmation
        Array(evaluation_result[:user_questions]).each do |question|
          text = question.to_s.strip
          next if text.empty?
          @user_questions << text unless @user_questions.include?(text)
        end

        # 兜底：条目归因为 needs_user_confirmation 却没给出问题时，用条目本身生成一个问题
        Array(evaluation_result[:items]).each do |item|
          next unless item[:attribution].to_s == 'needs_user_confirmation'

          question = "请确认：#{item[:requirement]}（缺少数据来源或判定口径）"
          @user_questions << question unless @user_questions.include?(question)
        end
      end

      collect_mapping_suggestions(scenario[:key], evaluation_result, attempt)
    end
  end

  # 是否"只剩需要用户确认的失败项"（没有任何脚本能修的问题，也没有环境映射问题）
  def needs_user_confirmation_only?(scenario_results)
    # 有分支映射根本没生成出来时，还有可修的东西，不能提前停轮
    return false if Array(scenario_results).any? { |s| s[:mapping_error] }

    failed = all_failed_items(scenario_results)
    return false if failed.empty?
    return false if failed.any? { |it| %w[script_issue env_mismatch].include?(it[:attribution].to_s) }

    failed.any? { |it| it[:attribution].to_s == 'needs_user_confirmation' }
  end

  # 需要用户确认时的返回结果：带上问题与当前产物
  def build_clarification_result(generation_result, scenario_results, attempts)
    {
      success: false,
      needs_user_confirmation: true,
      user_questions: @user_questions,
      code: generation_result[:code],
      command_mapping: generation_result[:command_mapping],
      script_name: generation_result[:script_name],
      description: generation_result[:description],
      evaluation: scenario_results.first && scenario_results.first[:evaluation],
      test_result: scenario_results.first && scenario_results.first[:test_result],
      scenarios: public_scenarios(scenario_results),
      branch_scenarios: branch_scenarios_payload(scenario_results),
      attempts: attempts,
      history: @attempt_history,
      final_suggestion: "需要您先确认以下信息，我才能把脚本做对：\n" +
                        @user_questions.map { |q| "- #{q}" }.join("\n"),
      mapping_supplements: all_mapping_supplements,
      mapping_supplement_notice: mapping_supplement_notice,
      unresolved_mapping_suggestions: pending_mapping_suggestions
    }
  end

  def all_mapping_supplements
    @mapping_supplements.values.flatten
  end

  # 供报告披露：本次生成过程中自动补充了哪些测试环境命令映射。
  # 必须明说——否则用户会把"通过"误当成脚本一次写对，而不知道测试环境被补过。
  def mapping_supplement_notice
    supplements = all_mapping_supplements
    return nil if supplements.empty?

    items = supplements.map do |s|
      attempt = s[:supplemented_at_attempt]
      attempt ? "#{s[:command]}（第 #{attempt} 轮补齐）" : s[:command]
    end
    "注意：为消除测试环境命令映射缺失，本次自动补充/保留了以下命令映射" \
      "（依据需求描述生成，属测试环境调整，非脚本逻辑改动）：#{items.join('、')}"
  end

  # 获取最终建议（3次失败后）
  def get_final_suggestion
    history_text = @attempt_history.map do |h|
      case h[:status]
      when :generation_failed
        "尝试 #{h[:attempt]}: 脚本生成失败 - #{h[:data][:error]}"
      when :completed
        scenarios = Array(h[:data][:scenarios])
        scenario_lines = scenarios.map do |s|
          test = s[:test_result] || {}
          failed_items = Array(s[:evaluation][:items]).reject { |it| it[:passed] }
          item_lines = failed_items.map do |it|
            "    - 未达成: #{it[:requirement]}｜期望: #{it[:expected]}｜实际: #{it[:observed]}｜归因: #{it[:attribution]}"
          end.join("\n")
          <<~SCENARIO
            场景【#{s[:name]}】:
            - 测试执行: #{test[:success] ? '成功' : "失败 - #{test[:error]}"}
            - 评估结果: #{s[:passed] ? '通过' : '未通过'}
            - 问题: #{Array(s[:evaluation][:issues]).join(', ')}
            - 建议: #{Array(s[:evaluation][:suggestions]).join(', ')}
            #{item_lines}
          SCENARIO
        end.join("\n")
        <<~ATTEMPT
          尝试 #{h[:attempt]}:
          - 生成脚本: 成功
          #{scenario_lines}
        ATTEMPT
      end
    end.join("\n")

    prompt = Prompts::AutoGenerate.final_suggestion(@description, history_text, MAX_ATTEMPTS)
    call_deepseek_for_suggestion(prompt)
  rescue StandardError => e
    # 兜底：最终建议的这次 LLM 调用失败时，不能连带把失败原因也吞掉。
    # 用最后一轮评估的结论拼出可读原因，保证页面一定有内容可显示。
    Rails.logger.error "[AutoGenerateService] 生成最终建议失败，改用兜底文案: #{e.class}: #{e.message}"
    fallback_final_suggestion
  end

  # 从尝试历史里拼出失败原因，作为 final_suggestion 的兜底
  def fallback_final_suggestion
    last = @attempt_history.reverse.find { |h| h[:status] == :completed }
    return '多次尝试后仍未通过评估，请补充更详细的需求描述或检查命令映射。' unless last

    parts = []
    Array(last[:data][:scenarios]).each do |scenario|
      next if scenario[:passed]

      evaluation = scenario[:evaluation] || {}
      parts << "场景【#{scenario[:name]}】评估未通过：#{evaluation[:evaluation]}" if evaluation[:evaluation].present?

      Array(evaluation[:items]).reject { |it| it[:passed] }.each do |it|
        line = "- [#{scenario[:name]}] 未达成：#{it[:requirement]}"
        line += "（期望：#{it[:expected]}；实际：#{it[:observed]}）" if it[:expected].present? || it[:observed].present?
        parts << line
      end

      issues = Array(evaluation[:issues])
      parts << "场景【#{scenario[:name]}】问题：#{issues.join('；')}" if issues.any?
      suggestions = Array(evaluation[:suggestions])
      parts << "场景【#{scenario[:name]}】建议：#{suggestions.join('；')}" if suggestions.any?
    end
    parts.join("\n")
  end

  # 调用 LLM API 获取最终建议
  def call_deepseek_for_suggestion(prompt)
    response = LlmRequestService.call(
      messages: [
        { role: 'system', content: Prompts::AutoGenerate.final_suggestion_system_prompt },
        { role: 'user', content: prompt }
      ],
      service_name: 'AutoGenerateService',
      step_name: 'final_suggestion'
    )

    content = response.dig('choices', 0, 'message', 'content')
    content || "无法获取建议"
  rescue => e
    "获取建议时发生错误: #{e.message}"
  end

  # 对外暴露的场景结果
  def public_scenarios(scenario_results)
    Array(scenario_results).map do |s|
      {
        key: s[:key],
        kind: s[:kind].to_s,
        name: s[:name],
        description: s[:description],
        command_mapping: s[:command_mapping],
        test_result: s[:test_result],
        evaluation: s[:evaluation],
        passed: s[:passed] == true
      }
    end
  end

  # 分支场景（供前端保存/回填）
  def branch_scenarios_payload(scenario_results)
    Array(scenario_results).select { |s| s[:kind] == :branch }.map do |s|
      {
        name: s[:name],
        description: s[:description],
        command_mapping: s[:command_mapping],
        passed: s[:passed] == true
      }
    end
  end

  # 构建成功结果（success 只代表主线通过；分支结果单独给出，仅供参考）
  def build_success_result(generation_result, main_result, branch_results, attempts)
    branches = Array(branch_results)
    {
      success: true,
      code: generation_result[:code],
      command_mapping: main_result[:command_mapping],
      script_name: generation_result[:script_name],
      description: generation_result[:description],
      test_result: main_result[:test_result],
      evaluation: main_result[:evaluation],
      scenarios: public_scenarios([main_result] + branches),
      branch_scenarios: branch_scenarios_payload(branches),
      branch_summary: {
        total: branches.size,
        passed: branches.count { |b| b[:passed] }
      },
      attempts: attempts,
      history: @attempt_history,
      # 报告披露：通过之前补过哪些测试环境映射
      mapping_supplements: all_mapping_supplements,
      mapping_supplement_notice: mapping_supplement_notice,
      # 即便通过，也可能存在需要用户确认的条目（信息不足）
      user_questions: @user_questions,
      needs_user_confirmation: @user_questions.any?
    }
  end

  # 构建失败结果
  def build_failure_result(final_suggestion, attempts)
    main = @last_scenario_results.first
    last_generation = @last_generation || {}

    {
      success: false,
      code: last_generation[:code],
      command_mapping: main ? main[:command_mapping] : last_generation[:command_mapping],
      script_name: last_generation[:script_name],
      description: last_generation[:description],
      test_result: main && main[:test_result],
      evaluation: main && main[:evaluation],
      scenarios: public_scenarios(@last_scenario_results),
      branch_scenarios: branch_scenarios_payload(@last_scenario_results),
      attempts: attempts,
      history: @attempt_history,
      final_suggestion: final_suggestion,
      # 报告披露：即便最终失败，也说明补过哪些映射、还差哪些没补
      mapping_supplements: all_mapping_supplements,
      mapping_supplement_notice: mapping_supplement_notice,
      unresolved_mapping_suggestions: pending_mapping_suggestions,
      # 需要用户确认的问题（信息不足时由评估提出）
      user_questions: @user_questions,
      needs_user_confirmation: @user_questions.any?
    }
  end
end

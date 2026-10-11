# frozen_string_literal: true

require 'rails_helper'

# 手工操作日志 → 需求描述框架
#
# 背景：日志里天然有逐字命令与真实回显，是需求描述里最难拿到的部分；但日志只说明"做了什么"，
# 说明不了"什么算通过"。所以本服务的核心契约是：日志里没有的判据一律留成【待确认#N】占位 +
# open_questions（每条最多两个候选），由用户点选或自己写——绝不编造。
RSpec.describe ScriptRequirementDraftService do
  let(:goal) { '核对两块单板的配置文件是否齐全' }
  let(:log) do
    <<~LOG
      Switch> cd /slot1
      slot1> ls
      config.dat
      version.txt
      slot1> cd ..
    LOG
  end

  def llm_returning(content)
    allow(LlmRequestService).to receive(:call).and_return(
      'choices' => [{ 'message' => { 'content' => content } }]
    )
  end

  def call_service(goal_value = goal, log_value = log)
    described_class.new(goal_value, log_value).call
  end

  describe '#call' do
    it '解析出框架、待确认项与提示' do
      llm_returning(<<~CONTENT)
        ```json
        {
          "description": "需求：核对单板配置文件\\n1. cd /slot1 进入 1 号单板\\n预期：【待确认#1】",
          "open_questions": [
            { "id": 1, "question": "1 号单板缺 version.txt 时判失败还是跳过？", "options": ["判失败", "跳过"] }
          ],
          "notes": ["日志中未发现提示符，已按平铺处理"]
        }
        ```
      CONTENT

      result = call_service

      expect(result[:success]).to be true
      expect(result[:description]).to include('cd /slot1')
      expect(result[:open_questions]).to eq([
        { id: 1, question: '1 号单板缺 version.txt 时判失败还是跳过？', options: ['判失败', '跳过'] }
      ])
      expect(result[:notes]).to eq(['日志中未发现提示符，已按平铺处理'])
      expect(result[:error]).to be_nil
    end

    it '候选项超过两个时截断到两个' do
      llm_returning(<<~CONTENT)
        { "description": "需求：【待确认#1】",
          "open_questions": [
            { "id": 1, "question": "阈值取哪个？", "options": ["< 70%", "< 80%", "< 90%"] }
          ] }
      CONTENT

      options = call_service[:open_questions].first[:options]

      expect(options.size).to eq(described_class::MAX_OPTIONS)
      expect(options).to eq(['< 70%', '< 80%'])
    end

    it '丢弃问题为空、非 Hash 的待确认项，并去掉重复 id' do
      llm_returning(<<~CONTENT)
        { "description": "需求：【待确认#1】",
          "open_questions": [
            "解释性文字",
            { "id": 1, "question": "" },
            { "id": 1, "question": "阈值取哪个？", "options": [] },
            { "id": 1, "question": "重复 id 应被丢弃", "options": [] }
          ] }
      CONTENT

      questions = call_service[:open_questions]

      expect(questions.size).to eq(1)
      expect(questions.first[:question]).to eq('阈值取哪个？')
    end

    it 'id 缺失时按顺序补号' do
      llm_returning(<<~CONTENT)
        { "description": "需求：【待确认#1】【待确认#2】",
          "open_questions": [
            { "question": "第一个问题", "options": [] },
            { "question": "第二个问题", "options": [] }
          ] }
      CONTENT

      expect(call_service[:open_questions].map { |q| q[:id] }).to eq([1, 2])
    end

    # 模型偶尔会忘记写占位符；前端靠占位符做回填，缺了就没法点选
    it '描述里缺占位符时，在末尾补出对应的待确认占位' do
      llm_returning(<<~CONTENT)
        { "description": "需求：核对配置文件",
          "open_questions": [
            { "id": 1, "question": "缺 version.txt 判失败还是跳过？", "options": ["判失败"] }
          ] }
      CONTENT

      description = call_service[:description]

      expect(description).to include('需要确认：')
      expect(description).to include('【待确认#1】：缺 version.txt 判失败还是跳过？')
    end

    it '模型未返回 description 时失败' do
      llm_returning('{ "open_questions": [] }')

      result = call_service

      expect(result[:success]).to be false
      expect(result[:error]).to be_present
    end

    it '模型回复不是 JSON 时失败且错误可见（不静默）' do
      llm_returning('抱歉，我无法完成这个请求。')

      result = call_service

      expect(result[:success]).to be false
      expect(result[:error]).to be_present
    end

    context '当日志超过长度上限' do
      let(:log) { 'a' * (described_class::MAX_LOG_LENGTH + 1) }

      it '直接失败、不调用 LLM，并提示上限' do
        expect(LlmRequestService).not_to receive(:call)

        result = call_service

        expect(result[:success]).to be false
        expect(result[:error]).to include(described_class::MAX_LOG_LENGTH.to_s)
      end
    end

    context '当目标为空' do
      it '失败且不调用 LLM' do
        expect(LlmRequestService).not_to receive(:call)

        result = call_service('   ')

        expect(result[:success]).to be false
        expect(result[:error]).to include('目标')
      end
    end

    context '当日志为空' do
      it '失败且不调用 LLM' do
        expect(LlmRequestService).not_to receive(:call)

        result = call_service(goal, '')

        expect(result[:success]).to be false
        expect(result[:error]).to include('日志')
      end
    end

    it 'LLM 调用抛异常时返回可见错误，不向外抛' do
      allow(LlmRequestService).to receive(:call).and_raise(StandardError, 'boom')

      result = call_service

      expect(result[:success]).to be false
      expect(result[:error]).to eq('boom')
    end

    # 日志是原样拼进提示词的：里面出现 #{...} 会被 Ruby 插值吃掉，必须转义成字面量
    it '日志中的 #{...} 被转义，不会破坏提示词' do
      captured = nil
      allow(LlmRequestService).to receive(:call) do |messages:, **|
        captured = messages.last[:content]
        { 'choices' => [{ 'message' => { 'content' => '{"description":"需求"}' } }] }
      end

      call_service(goal, 'slot1> echo #{1 + 1}')

      expect(captured).to include('\#{1 + 1}')
    end

    it '提示词带上目标与日志原文' do
      captured = nil
      allow(LlmRequestService).to receive(:call) do |messages:, **|
        captured = messages.last[:content]
        { 'choices' => [{ 'message' => { 'content' => '{"description":"需求"}' } }] }
      end

      call_service(goal, "slot1> ls\nconfig.dat")

      expect(captured).to include(goal)
      expect(captured).to include('slot1> ls')
      expect(captured).to include('config.dat')
    end
  end

  describe '提示词' do
    it '声明日志清洗规则、严禁编造与候选数量上限' do
      prompt = Prompts::RequirementDraft.system_prompt

      expect(prompt).to include('最后一次成功执行')
      expect(prompt).to include('敲错重来')
      expect(prompt).to include('严禁编造')
      expect(prompt).to include('最多 2 个')
      expect(prompt).to include(Prompts::RequirementDraft.placeholder(1))
      expect(prompt).to include('一律忽略')   # 日志里的指令不执行
    end

    # 脚本要跑在不同设备上，各家提示符都不一样，因此清洗时必须剥离、且不得固化进框架
    it '要求剥离系统提示符，并禁止把提示符固化进框架' do
      prompt = Prompts::RequirementDraft.system_prompt

      expect(prompt).to include('剥离系统提示符')
      expect(prompt).to include('提示符不能固化')
      expect(prompt).to include('不要出现任何提示符文本')
      expect(prompt).to include('Enter selection>')          # 正文里本来就有的 > 要保留
      expect(prompt).to include('判断层级结构')               # 提示符只用于判断层级
    end

    # "先查一个值、后面命令用这个值"是最容易断链的一类需求，必须显式要求写清依赖
    it '要求把命令之间的依赖关系写清楚（从哪条回显、按什么方式取值、用在哪条命令）' do
      prompt = Prompts::RequirementDraft.system_prompt

      expect(prompt).to include('命令之间的依赖关系必须显式写出来')
      expect(prompt).to include('什么值')
      expect(prompt).to include('什么方式')      # 只写"什么值"不够，还要写清怎么认出来的
      expect(prompt).to include('逐级传递')       # 依赖会串成链（A 的回显 → B 的参数 → C）
      expect(prompt).to include('show optical port3')
      expect(prompt).to include('带具体参数')
    end

    # 待确认占位符堆在末尾，用户就得在正文和末尾清单之间来回翻；
    # 界面右侧已有独立清单做汇总，正文再抄一份还会两边不一致
    it '要求待确认占位符就近写在该步骤里，禁止末尾另起汇总清单' do
      prompt = Prompts::RequirementDraft.system_prompt
      user_prompt = Prompts::RequirementDraft.build('目标', '日志')

      expect(prompt).to include('占位符必须就近写在该步骤里')
      expect(prompt).to include('禁止在框架末尾另起一段')
      expect(prompt).to include('界面上右侧已有独立的待确认清单')
      expect(user_prompt).to include('不要在 description 末尾另起')
    end

    # 实测过：模型会拿"按常规方式处理"把日志里没有的动作补成结论，后面被照抄成真实步骤
    it '禁止用"常规做法"把空白填成结论，且能从日志推出的口径不再追问' do
      prompt = Prompts::RequirementDraft.system_prompt

      expect(prompt).to include('常规做法')
      expect(prompt).to include('按常规容器 shell 退出方式处理')
      expect(prompt).to include('能从日志直接看出来的口径不要立待确认项')
    end

    # 摘要丢掉的原文，后面生成命令映射时只能靠编来补（实测：ssh 那步的登录 banner
    # 被模型凭空编了一段假的 Ubuntu banner，版本号/IP/时间戳全是假的）
    it '要求报文原样照抄、禁止省略或概括' do
      prompt = Prompts::RequirementDraft.system_prompt

      expect(prompt).to include('报文本原样保留，禁止省略')
      expect(prompt).to include('一律逐字照抄原文')
      expect(prompt).to include('禁止概括')
      expect(prompt).to include('禁止替用户删')
      expect(prompt).to include('Last login')   # 点名了这类"看起来无关"的内容同样要照抄
      expect(prompt).not_to include('可以概括成一句话')
    end

    # 步骤标记要单独一行，便于肉眼扫读与后续按步骤定位占位符
    it '要求步骤标记单独占一行且格式固定' do
      prompt = Prompts::RequirementDraft.system_prompt
      user_prompt = Prompts::RequirementDraft.build('目标', '日志')
      marker = '----------------------步骤1----------------------'

      expect(prompt).to include('每个步骤的标记必须单独占一行')
      expect(prompt).to include(marker)
      expect(prompt).to include('两边各 22 个短横线')
      expect(prompt).to include('不要用"步骤 1："')
      expect(user_prompt).to include('每个步骤的标记单独占一行')
      expect(user_prompt).to include(marker.sub('1', 'N'))
    end

    it '要求日志里出现的每条命令都算一个步骤（含登录/进入容器/切目录）' do
      prompt = Prompts::RequirementDraft.system_prompt

      expect(prompt).to include('日志里出现的每一条命令都算一个步骤')
      expect(prompt).to include('ssh xxx')
      expect(prompt).to include('docker exec')
      expect(prompt).to include('一条都不要丢')
    end

    # 这些步骤默认都由脚本下发；只有用户明确说不需要才跳过（否则模型会自己判断省略，
    # 实测漏发过 ssh）
    it '声明这些步骤默认由脚本下发，只有明确说明才跳过' do
      prompt = Prompts::RequirementDraft.system_prompt

      expect(prompt).to include('这些命令默认都由脚本下发')
      expect(prompt).to include('该步骤不需要脚本下发')
      expect(prompt).to include('不要自己判断省略')
    end

    it '用户提示词声明只作素材，且带上 JSON 输出契约' do
      prompt = Prompts::RequirementDraft.build('目标A', '日志B')

      expect(prompt).to include('仅作素材')
      expect(prompt).to include('目标A')
      expect(prompt).to include('日志B')
      expect(prompt).to include('open_questions')
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScriptGenerationService do
  let(:api_content) do
    <<~CONTENT
      ```ruby
      module QingxunScript
        class Refined < Qingxun::DeviceScript
          def run(connection); end
        end
      end
      ```
      ```json
      { "commands": [ { "command": "show version", "response": "VRP 5.170" } ] }
      ```
      ```script_name
      微调脚本
      ```
      ```description
      微调后的脚本
      ```
    CONTENT
  end

  before do
    allow(LlmRequestService).to receive(:call).and_return(
      'choices' => [{ 'message' => { 'content' => api_content } }]
    )
  end

  describe '#call' do
    it '普通模式：按描述生成并解析代码/映射/名称/描述' do
      result = described_class.new('巡检设备').call

      expect(result[:code]).to include('class Refined')
      expect(result[:command_mapping]).to eq([{ command: 'show version', response: 'VRP 5.170' }])
      expect(result[:script_name]).to eq('微调脚本')
      expect(result[:description]).to eq('微调后的脚本')
    end

    it '微调模式：提示词包含现有代码、主线与分支描述' do
      captured = nil
      allow(LlmRequestService).to receive(:call) do |messages:, **|
        captured = messages.last[:content]
        { 'choices' => [{ 'message' => { 'content' => api_content } }] }
      end

      described_class.new(
        '巡检设备',
        existing_code: 'module QingxunScript; class Old; end; end',
        branches: [{ name: '型号不符', description: '设备返回 ZXCTN 6500-2 的完整流程' }]
      ).call

      expect(captured).to include('微调现有脚本')
      expect(captured).to include('class Old')
      expect(captured).to include('最小必要改动')
      expect(captured).to include('型号不符')
      expect(captured).to include('ZXCTN 6500-2')
    end
  end

  describe '类名后缀（script_uid）' do
    let(:code) do
      "module QingxunScript\n  class ProcessMemCheck < Qingxun::DeviceScript\n  end\nend"
    end

    it '用传入的 script_uid 作为类名后缀（同一脚本稳定不变）' do
      uid = 'a1b2c3d4e5f60718'
      out = described_class.new('需求', script_uid: uid).send(:ensure_unique_class_name, code.dup)

      expect(out).to include("class ProcessMemCheck_#{uid} < Qingxun::DeviceScript")
    end

    it '代码已带同一后缀时不再追加（微调幂等，避免 Foo_uid_uid）' do
      uid = 'a1b2c3d4e5f60718'
      already = code.sub('ProcessMemCheck', "ProcessMemCheck_#{uid}")

      out = described_class.new('需求', script_uid: uid).send(:ensure_unique_class_name, already.dup)

      expect(out).to eq(already)
      expect(out.scan("_#{uid}").size).to eq(1)
    end

    it '未提供 script_uid 时回退为随机 16 位十六进制' do
      out = described_class.new('需求').send(:ensure_unique_class_name, code.dup)

      expect(out).to match(/class ProcessMemCheck_[0-9a-f]{16} < Qingxun::DeviceScript/)
    end
  end

  # 树状命令映射：命中带 children 的命令进入下一层上下文，同一命令在不同上下文下
  # 回显不同。mock 是仅模拟服务器使用的导航元数据（真机不生效）。
  describe '嵌套命令映射（上下文树）' do
    let(:api_content) do
      <<~CONTENT
        ```ruby
        module QingxunScript
          class TreeDemo < Qingxun::DeviceScript
            def run(connection); end
          end
        end
        ```
        ```json
        {
          "commands": [
            { "command": "switch board 1", "response": "Board 1 selected.",
              "children": [
                { "command": "ls", "response": "card1  card2" },
                { "command": "exit", "response": "", "mock": { "exit_level": 1 } }
              ] }
          ]
        }
        ```
        ```script_name
        树形映射脚本
        ```
        ```description
        验证嵌套映射
        ```
      CONTENT
    end

    it '解析出 children 与 mock 导航元数据' do
      result = described_class.new('按单板巡检').call

      node = result[:command_mapping].first
      expect(node[:command]).to eq('switch board 1')
      expect(node[:children].map { |c| c[:command] }).to eq(%w[ls exit])
      expect(node[:children].last[:mock]).to eq(exit_level: 1)
    end
  end

  describe '提示词' do
    it 'build_refine 声明"微调不是重写"，并带上现有代码与分支描述' do
      prompt = Prompts::ScriptGeneration.build_refine(
        existing_code: 'class Old; end',
        mainline_description: '主线需求',
        branches: [{ name: '分支A', description: '分支A的场景' }]
      )

      expect(prompt).to include('微调，不是重写')
      expect(prompt).to include('class Old')
      expect(prompt).to include('分支A')
      expect(prompt).to include('分支A的场景')
    end

    # 实测：需求里 `ssh qingyun` 是一个步骤，但生成出的脚本没下发它
    #（被当成"建连应由框架负责"而省略），跑起来就少了这一步
    it '要求需求里列出的每条命令都由脚本下发（除非明确说明不需要）' do
      build_prompt = Prompts::ScriptGeneration.build('', '需求')
      refine_prompt = Prompts::ScriptGeneration.build_refine(
        existing_code: 'class Old; end', mainline_description: '需求'
      )
      guide = Prompts.command_mapping_format_guide

      expect(build_prompt).to include('需求里列出的每条命令都必须由脚本下发')
      expect(build_prompt).to include('连接应该由框架负责')
      expect(refine_prompt).to include('每条命令都必须由脚本下发')
      expect(guide).to include('映射要覆盖脚本会下发的每一条命令')
    end

    # 用户要求在客户端日志里能看到"当前走到哪一步"：描述里本来就有 ----步骤N---- 标记，
    # 但原来的提示词从没要求脚本把它打进日志，只能靠框架记的 CMD/OUTPUT 猜走到哪了
    it '要求脚本按描述里的步骤标记打印步骤开始/结束日志' do
      build_prompt = Prompts::ScriptGeneration.build('', '需求')
      refine_prompt = Prompts::ScriptGeneration.build_refine(
        existing_code: 'class Old; end', mainline_description: '需求'
      )

      expect(build_prompt).to include('步骤边界日志')
      expect(build_prompt).to include('log_info("[步骤3] 开始：')
      expect(build_prompt).to include('log_info("[步骤3] 结束")')
      expect(build_prompt).to include('按 `run` 里的执行顺序从 1 开始连续编号')
      # 与"禁止把原始回显抄进日志"那条并存，必须说清不冲突
      expect(build_prompt).to include('不与第 4 条冲突')

      expect(refine_prompt).to include('步骤边界日志')
      expect(refine_prompt).to include('log_info("[步骤N] 开始：')
      expect(refine_prompt).to include('保留编号与写法')
    end

    # 实测：需求里写了"预期：本回显应得到 Gi0/2、Gi0/4"，生成出的脚本就把它原样实现成
    # `bad_ports.sort == ["Gi0/2", "Gi0/4"]`，换一台设备非 connected 端口不同就会误判为失败。
    # 需求里的「预期」是给评估方用的判定口径，不是脚本要比对的期望值
    it '禁止把需求预期或样例回显里的具体值写成通过条件' do
      build_prompt = Prompts::ScriptGeneration.build('', '需求')
      refine_prompt = Prompts::ScriptGeneration.build_refine(
        existing_code: 'class Old; end', mainline_description: '需求'
      )

      expect(build_prompt).to include('「预期」是给评估用的判定口径')
      expect(build_prompt).to include('不得把预期里')
      expect(build_prompt).to include('写成比较常数')
      expect(build_prompt).to include('["Gi0/2", "Gi0/4"]')
      expect(build_prompt).to include('拿它反推阈值')     # 样例值也不能拿来当阈值用
      expect(build_prompt).to include('规则常量')          # 但规则本身的常量（阈值/状态字面量）该用就用
      expect(refine_prompt).to include('不得把需求「预期」')
      expect(refine_prompt).to include('record_check` 的 `expected` 写判据本身')
    end

    # 实测：生成的脚本名是 PortCpuCheck / InterfaceCpuCheck 这类英文标识符（拿类名当显示名），
    # 用户在脚本列表里看不出这个脚本干什么
    it '要求脚本名称用中文显示名，同时把类名钉在 ASCII' do
      build_prompt = Prompts::ScriptGeneration.build('', '需求')
      refine_prompt = Prompts::ScriptGeneration.build_refine(
        existing_code: 'class Old; end', mainline_description: '需求'
      )
      system_prompt = Prompts::ScriptGeneration.system_prompt

      expect(build_prompt).to include('**用中文**、简短')
      expect(build_prompt).to include('接口状态与CPU巡检')
      expect(build_prompt).to include('英文标识符式')
      expect(build_prompt).to include('类名不要出现中文或其它非 ASCII 字符')
      expect(refine_prompt).to include('**用中文**、简短')
      expect(refine_prompt).to include('沿用原脚本名称的中文风格')
      expect(system_prompt).to include('类名用 **ASCII** 驼峰')
      expect(system_prompt).to include('显示名**可以是中文')
    end

    # 微调要求输出完整脚本，现有代码被转义成 `\#{` 后模型可能把转义照抄回文件；
    # 评估侧也已经因为转义展示提过 21 条"使用了转义字符串"的假问题
    it '微调提示词原样展示现有代码，不做插值转义' do
      refine_prompt = Prompts::ScriptGeneration.build_refine(
        existing_code: 'log_info("#{list}")', mainline_description: '需求'
      )

      expect(refine_prompt).to include('log_info("#{list}")')
      expect(refine_prompt).not_to include('\#{list}')
    end

    # 实测：解析表格时靠"按空白切分 + 状态枚举白名单"，Name 为空的行会整体错位一列，
    # 换台设备状态文案不同（up/down/suspended）就漏解析——表格要按表头定位列
    it '要求表格类回显按表头定位字段，不写死列宽与状态枚举' do
      build_prompt = Prompts::ScriptGeneration.build('', '需求')
      refine_prompt = Prompts::ScriptGeneration.build_refine(
        existing_code: 'class Old; end', mainline_description: '需求'
      )

      expect(build_prompt).to include('表格类回显按表头定位字段')
      expect(build_prompt).to include('列位置')
      expect(build_prompt).to include('按空白切分')        # Name 为空的行会错位
      expect(build_prompt).to include('解析时不要用状态枚举白名单')
      expect(refine_prompt).to include('表头定位字段')
    end

    # 实测：描述里只给了"登录 banner（含…）"的摘要，模型就凭空编了一段假的 Ubuntu banner
    # （版本号/IP/时间戳全假）。响应只能取自描述原文，没有就留空
    it '命令映射格式说明要求 response 只能取自描述原文，禁止编造' do
      guide = Prompts.command_mapping_format_guide

      expect(guide).to include('response 只能逐字取自用户描述原文')
      expect(guide).to include('就留空字符串')
      expect(guide).to include('严禁凭常识补一段看起来真实的回显')
      expect(guide).to include('不要编造版本号、IP、主机名、时间戳')
    end

    # 提示符因设备而异，映射里写死会误导生成的脚本去依赖它
    it '命令映射格式说明要求命令与回显都不带提示符，且不含任何提示符字段' do
      guide = Prompts.command_mapping_format_guide

      expect(guide).to include('不许带提示符')
      expect(guide).to include('没有、也不需要')
      expect(guide).not_to include('mock.prompt')
      expect(guide).not_to include('"prompt"')
    end

    # 映射是逐字精确匹配：后面依赖前面查出来的值的命令，必须写出具体形式，
    # 否则脚本下发时会拿到 not recognized（实测过）
    it '命令映射格式说明要求把「依赖前面回显的派生命令」写成具体形式' do
      guide = Prompts.command_mapping_format_guide

      expect(guide).to include('派生命令')
      expect(guide).to include('show optical port3')
      expect(guide).to include('not recognized')
    end

    it '生成与微调提示词都声明嵌套格式及"仅模拟器生效"的边界' do
      build_prompt = Prompts::ScriptGeneration.build('', '需求')
      refine_prompt = Prompts::ScriptGeneration.build_refine(
        existing_code: 'class Old; end',
        mainline_description: '需求'
      )

      [build_prompt, refine_prompt].each do |prompt|
        expect(prompt).to include('children')
        expect(prompt).to include('mock.exit_level')
        expect(prompt).to include('仅测试模拟器使用')
      end
    end
  end
end

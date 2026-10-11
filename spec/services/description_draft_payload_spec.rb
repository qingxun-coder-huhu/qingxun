# frozen_string_literal: true

require 'rails_helper'

# 描述类 LLM 载荷的规范化（两条路径共用）
#
# 从 ScriptRequirementDraftService 抽出来的公共逻辑：手工日志生成框架 与 按真实日志改进描述
# 返回的是同一形状的 JSON，而"待确认占位符"是平台级契约（界面靠占位符做点选回填）。
# 这里直接钉住抽出来的这几个纯函数，两处调用方共用一份。
RSpec.describe DescriptionDraftPayload do
  describe '.parse_json' do
    it '能从带 ```json 围栏与前后说明的回复里抓到 JSON 对象' do
      content = "好的，结果如下：\n```json\n{\"description\":\"描述\"}\n```\n希望有帮助。"

      expect(described_class.parse_json(content)).to eq('description' => '描述')
    end

    it '抓不到 JSON 或解析失败时返回 nil（交给调用方转成可见错误）' do
      expect(described_class.parse_json('抱歉，我无法完成这个请求。')).to be_nil
      expect(described_class.parse_json('{ 坏掉的 json')).to be_nil
      expect(described_class.parse_json(nil)).to be_nil
    end

    it '顶层不是对象（例如数组）时返回 nil' do
      expect(described_class.parse_json('[1,2,3]')).to be_nil
    end
  end

  describe '.normalize_questions' do
    it '丢弃非 Hash 与空问题，id 缺失时按顺序补号' do
      questions = described_class.normalize_questions([
        '解释性文字',
        { 'question' => '第一个问题', 'options' => [] },
        { 'question' => '' },
        { 'question' => '第二个问题' }
      ])

      expect(questions.map { |q| q[:id] }).to eq([1, 2])
      expect(questions.map { |q| q[:question] }).to eq(['第一个问题', '第二个问题'])
    end

    it 'id 重复只保留第一条（占位符区分不了同一个 id 的两条）' do
      questions = described_class.normalize_questions([
        { 'id' => 1, 'question' => '保留这条' },
        { 'id' => 1, 'question' => '丢掉这条' }
      ])

      expect(questions.size).to eq(1)
      expect(questions.first[:question]).to eq('保留这条')
    end

    it '候选项截断到上限并丢掉空串' do
      questions = described_class.normalize_questions([
        { 'id' => 1, 'question' => '阈值取哪个？', 'options' => ['< 70%', '', '< 80%', '< 90%'] }
      ])

      expect(questions.first[:options]).to eq(['< 70%', '< 80%'])
      expect(questions.first[:options].size).to eq(described_class::MAX_OPTIONS)
    end

    it '非数组输入返回空数组' do
      expect(described_class.normalize_questions(nil)).to eq([])
      expect(described_class.normalize_questions('x')).to eq([])
    end
  end

  describe '.ensure_placeholders' do
    it '描述里没有对应占位符时，在末尾补一段"需要确认："' do
      questions = [{ id: 1, question: '缺 version.txt 判失败还是跳过？', options: [] }]

      description = described_class.ensure_placeholders('需求：核对配置文件', questions)

      expect(description).to include('需要确认：')
      expect(description).to include('【待确认#1】：缺 version.txt 判失败还是跳过？')
    end

    # 用户报过：兜底原来把漏写的占位符堆在描述**末尾**，正文里那处判据旁边看不到"这里还不确定"。
    # 模型提的问题通常自带步骤号，就该放回那一步里去。
    it '问题里认得出步骤号时，占位符插进那一步（不堆在末尾）' do
      description = <<~DESC
        ----------------------步骤1----------------------
        命令：df -h
        预期：根分区 Use% < 80%
        ----------------------步骤6----------------------
        命令：docker top qingxun
        预期：存在 puma 主进程
        ----------------------步骤7----------------------
        命令：docker stats --no-stream
        预期：CPU% < 80%
      DESC
      questions = [{ id: 1, question: '步骤6 中 cluster worker 是否仍作为判定条件？', options: [] }]

      result = described_class.ensure_placeholders(description, questions)
      lines = result.split("\n")

      expect(result).not_to include('需要确认：')
      # 落在步骤6 与步骤7 之间 —— 即"步骤6 那一步里"，而不是末尾
      expect(lines.index { |l| l.include?('【待确认#1】') })
        .to be > lines.index { |l| l.include?('docker top qingxun') }
      expect(lines.index { |l| l.include?('【待确认#1】') })
        .to be < lines.index { |l| l.include?('----------------------步骤7') }
    end

    it '问题里认不出步骤号时，仍退回末尾汇总（不能让它没处可填）' do
      description = "----------------------步骤1----------------------\n预期：根分区 Use% < 80%"
      questions = [{ id: 2, question: '阈值到底取多少？', options: [] }]

      result = described_class.ensure_placeholders(description, questions)

      expect(result).to include('需要确认：')
      expect(result).to include('【待确认#2】：阈值到底取多少？')
    end

    it '描述里已经就近写了占位符时原样返回，不重复补' do
      questions = [{ id: 1, question: '阈值？', options: [] }]
      original = "步骤1\n预期：【待确认#1】"

      expect(described_class.ensure_placeholders(original, questions)).to eq(original)
    end
  end

  describe '.normalize_notes' do
    it '去掉空串与首尾空白' do
      expect(described_class.normalize_notes(['  改了预期  ', '', nil, '  '])).to eq(['改了预期'])
    end

    it '非数组输入返回空数组' do
      expect(described_class.normalize_notes(nil)).to eq([])
    end
  end
end

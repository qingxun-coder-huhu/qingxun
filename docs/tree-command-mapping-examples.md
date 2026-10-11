# 树状命令映射：页面需求描述示例

把下面的描述整段粘贴到「生成脚本」页面的需求输入框即可。要点是**逐字写出每条命令和它在
不同上下文下的真实回显**——提示词要求"命令映射中的内容必须全文引用用户的输入"，描述里
写清楚了，模型才会生成带 `children` 的树，而不是把所有回显塞成一条。

---

## 示例一：目录式 CLI，两块单板配置文件不同（推荐先试这个）

```
设备是 ZXCTN 传输设备，CLI 是目录式的：用 cd 进入某个目录，用 ls 看目录内容，
用 cd .. 回到上一层。设备有两块单板，各自目录下的文件不同。请生成一份巡检脚本，
逐块核对配置文件是否齐全。

设备真实回显如下（命令映射必须原文引用这些回显）：

1. show version —— 全局命令，在任意目录下都可执行，回显：
ZXCTN 5.170 (R) software, Version 5.170.20
Copyright (c) 2020 ZTE Corporation

2. cd /slot1 —— 进入 1 号单板目录，该命令无回显（收到空字符串）

3. ls —— 在 1 号单板目录下执行，回显：
config.dat
license.txt
version.txt

4. cat version.txt —— 在 1 号单板目录下执行，回显：
V5.170.20

5. cd .. —— 返回根目录，该命令无回显

6. cd /slot2 —— 进入 2 号单板目录，该命令无回显

7. ls —— 在 2 号单板目录下执行，回显：
config.dat
alarm.log

8. cat version.txt —— 在 2 号单板目录下执行，回显：
%Error: no such file: version.txt

9. cd .. —— 返回根目录，该命令无回显

检查点要求：
- 记录 1 号单板的 ls 结果，必须同时包含 config.dat 与 version.txt，缺一即判定失败；
- 记录 1 号单板 cat version.txt 的版本号，应为 V5.170.20；
- 记录 2 号单板的 ls 结果，必须包含 config.dat；
- 2 号单板执行 cat version.txt 会报 no such file，脚本必须把这条如实记为失败检查点，
  说明"2 号单板缺少 version.txt"，不要当成测试环境错误吞掉或忽略；
- 最后按单板分别总结，不要把两块单板的结果混在一起。
```

### 这段描述应当生成的映射

模型应产出下面这棵树（在页面的命令映射框里可以直接核对）：`ls` 与 `cat version.txt`
在 `/slot1`、`/slot2` 下各有一份，`cd ..` 用 `exit_level: 1` 声明"回上一层"。

```json
{
  "commands": [
    {
      "command": "show version",
      "response": "ZXCTN 5.170 (R) software, Version 5.170.20\nCopyright (c) 2020 ZTE Corporation"
    },
    {
      "command": "cd /slot1",
      "response": "",
      "children": [
        { "command": "ls", "response": "config.dat\nlicense.txt\nversion.txt" },
        { "command": "cat version.txt", "response": "V5.170.20" }
      ]
    },
    {
      "command": "cd /slot2",
      "response": "",
      "children": [
        { "command": "ls", "response": "config.dat\nalarm.log" },
        { "command": "cat version.txt", "response": "%Error: no such file: version.txt" }
      ]
    },
    {
      "command": "cd ..",
      "response": "",
      "mock": { "exit_level": 1 }
    }
  ]
}
```

### 为什么这样写

- `show version` 只写在根层：查找规则是"就近优先、逐级向上兜底到根"，所以全局命令在
  任何目录下都能命中，不必每层重复。
- `cd ..` 只写在根层、声明 `exit_level: 1`：从任意深度执行都会向根方向退一层，等价于
  真实的 `cd ..`；在根目录执行则原地不动。
- `cd /slot1` 与 `cd /slot2` 是**对等**的根层节点。脚本即使在 `/slot1` 里直接下发
  `cd /slot2` 也不会嵌错层级——进入某层时上下文栈会被替换成该节点的完整祖先链。

---

## 示例二：单板 + 端口命令，同一命令回显不同

```
设备是 ZXCTN 传输设备，可以用 switch board 1 和 switch board 2 切到不同单板，
在单板下执行 show port state 查看该单板的端口状态。请生成脚本核对两块单板的端口。

设备真实回显如下（命令映射必须原文引用这些回显）：

1. show version —— 全局命令，回显：
ZXCTN 5.170 (R) software, Version 5.170.20

2. switch board 1 —— 切到 1 号单板，回显：
Board 1 selected.

3. show port state —— 在 1 号单板下执行，回显：
Port 1  up   1000M
Port 2  up   1000M
Port 3  down 0M
Port 4  up   1000M

4. exit —— 返回上一层，该命令无回显

5. switch board 2 —— 切到 2 号单板，回显：
Board 2 selected.

6. show port state —— 在 2 号单板下执行，回显：
Port 1  down 0M
Port 2  down 0M

7. exit —— 返回上一层，该命令无回显

检查点要求：
- 1 号单板应有 4 个端口，其中 3 个 up、1 个 down；端口 3 为 down 属于已知正常现象，
  记为通过的检查点并说明原因，不要判为故障；
- 2 号单板应有 2 个端口且全部 down，脚本必须如实记为失败检查点，指出"2 号单板整板端口
  不可用"；
- 两块单板的端口数量不同，脚本要分别记录，不能复用同一个解析结果。
```

### 这段描述应当生成的映射

```json
{
  "commands": [
    { "command": "show version", "response": "ZXCTN 5.170 (R) software, Version 5.170.20" },
    {
      "command": "switch board 1",
      "response": "Board 1 selected.",
      "children": [
        {
          "command": "show port state",
          "response": "Port 1  up   1000M\nPort 2  up   1000M\nPort 3  down 0M\nPort 4  up   1000M"
        }
      ]
    },
    {
      "command": "switch board 2",
      "response": "Board 2 selected.",
      "children": [
        { "command": "show port state", "response": "Port 1  down 0M\nPort 2  down 0M" }
      ]
    },
    { "command": "exit", "response": "", "mock": { "exit_level": 1 } }
  ]
}
```

---

## 示例三：三层目录，`cd ..` 只退一层、`exit` 才退到根

前两个例子只有两层，退出必然是回根，看不出区别。这个例子是"根 → 单板 → 子卡"三层，
并且明确区分两种退出：`cd ..` 只退一层，`exit` 直接回根。

```
设备是 ZXCTN 传输设备，CLI 是目录式的：cd 进入目录，ls 看目录内容，cd .. 返回上一层，
exit 直接回到根目录。1 号单板下面还有 2 号子卡，请生成脚本核对 2 号子卡的端口状态。

设备真实回显如下（命令映射必须原文引用这些回显）：

1. show version —— 全局命令，在任意目录下都可执行，回显：
ZXCTN 5.170 (R) software, Version 5.170.20
Copyright (c) 2020 ZTE Corporation

2. cd /slot1 —— 进入 1 号单板目录，无回显

3. ls —— 在 /slot1 下执行，回显：
card1
card2

4. cd card2 —— 进入 2 号子卡目录，无回显

5. ls —— 在 /slot1/card2 下执行，回显：
port1.status
port2.status
port3.status

6. cat port1.status —— 在 /slot1/card2 下执行，回显：
up

7. cd .. —— 从 2 号子卡返回上一层（即 1 号单板），无回显；注意它只退一层，
   不能直接跳回根目录

8. ls —— 第 7 步之后再次执行，回显必须仍是：
card1
card2

9. cd .. —— 从 1 号单板返回根目录，无回显

10. 重新 cd /slot1、cd card2 进入 2 号子卡后，执行 exit —— 直接回到根目录，无回显

11. show version —— 回到根目录后再执行一次，回显同第 1 条

检查点要求：
- 记录 /slot1/card2 的 ls 结果，应同时包含 port1.status、port2.status、port3.status；
- 记录 cat port1.status 的内容，应为 up；
- 第 8 步的 ls 结果必须与第 3 步一致（都是 card1、card2），据此确认 cd .. 只退了一层；
  若第 8 步拿到的是根目录内容，说明退出层级不对，必须判为失败；
- 第 10 步 exit 之后应位于根目录，且第 11 步 show version 仍能正常拿到回显；
- 最后说明 cd .. 与 exit 的区别：前者退一层，后者退到根。
```

### 这段描述应当生成的映射

关键只有一处：`cd ..` 声明 `exit_level: 1`（退一层），`exit` 声明 `exit_level: 0`（退到根）。

```json
{
  "commands": [
    {
      "command": "show version",
      "response": "ZXCTN 5.170 (R) software, Version 5.170.20\nCopyright (c) 2020 ZTE Corporation"
    },
    {
      "command": "cd /slot1",
      "response": "",
      "children": [
        { "command": "ls", "response": "card1\ncard2" },
        {
          "command": "cd card2",
          "response": "",
          "children": [
            { "command": "ls", "response": "port1.status\nport2.status\nport3.status" },
            { "command": "cat port1.status", "response": "up" }
          ]
        }
      ]
    },
    { "command": "cd ..", "response": "", "mock": { "exit_level": 1 } },
    { "command": "exit", "response": "", "mock": { "exit_level": 0 } }
  ]
}
```

### 为什么这样写

- **`exit_level` 是相对"当前所在深度"的，不是绝对层号。** 所以根层这一条
  `"cd .."` + `exit_level: 1` 就等价于"处处退一层"：在 2 号子卡（第 2 层）执行会落到
  1 号单板，在 1 号单板（第 1 层）执行才落到根。根层这一条 `exit` + `exit_level: 0`
  则是"处处退到根"。这正是需求里"有的退回上一层、有的退回顶层"的表达方式。
- 如果更希望显式一点，也可以在每一层的 `children` 里各写一条 `cd ..`，都用
  `exit_level: 1`——查找是就近优先，子卡层的声明会优先命中；效果与上面完全一致。
- 第 8 步的 `ls` 是这段描述里最有价值的检查点：它是唯一能区分"退一层"和"退到根"的
  观测点。只写"能退出去"是测不出来的。
- 在子卡层的 `children` 里没有 `cd ..`，也能命中根层那条，靠的是"逐级向上兜底到根"
  的查找规则——这与"退到根"是两回事，别混了：兜底决定**哪条命令生效**，
  `exit_level` 决定**生效后退到哪一层**。

---

## 在页面上怎么验证

1. 把描述粘进需求框，点生成；等出结果后看**命令映射**区域是否出现 `children` 与
   `mock.exit_level`，而不是一条条平铺的命令。
2. 直接点调试。脚本会在模拟设备上跑，日志里会看到同一条 `ls` / `show port state`
   在不同上下文下拿到不同回显；如果映射没生成成树，这一步会出现
   `Command 'xxx' not recognized.`，或两块单板拿到同一份回显。
3. **不要把提示符写进映射**：同一个脚本要跑在不同设备上，各家提示符都不一样
   （`Switch>`、`slot1>`、`(config)#` …）。映射里的 `command` 只写裸命令（`ls`，
   不是 `slot1> ls`）、`response` 只写设备输出，不要带提示符前缀或提示符行。
   映射里也**没有**任何提示符字段可用——模拟器用自己的默认提示符，脚本判断命令结束走的是
   通用规则（行尾 `>`/`#`/`$`），不依赖某个具体提示符。

### 排查提示

- **生成的映射仍是平的**：描述里没写清"同一命令在不同上下文下回显不同"，或没给出
  进入/退出命令。把上面的"执行流程 + 逐字回显"补全即可。
- **报 `Command 'x' not recognized.`**：脚本下发的命令在描述里没逐字出现，或写在了
  错误的层级。映射里查不到时会逐级向上兜底到根，仍然找不到才报这个错。
- **两块单板拿到同一份回显**：模型把子命令写到了根层。把回显写进对应的
  `children`，或在描述里强调"该命令只在某块单板下执行"。

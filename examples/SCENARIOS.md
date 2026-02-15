# girb-mcp デバッグ実験シナリオ

## 準備

Claude Codeの設定に girb-mcp を追加する（まだの場合）：

```json
{
  "mcpServers": {
    "girb-mcp": {
      "command": "bundle",
      "args": ["exec", "girb-mcp"],
      "cwd": "/home/rira/rira100000000/girb/girb-mcp"
    }
  }
}
```

---

## シナリオ1: 割引計算のバグを見つける

**ファイル:** `examples/01_simple_bug.rb`

**背景:** カートの合計金額が1000円以上なら10%割引されるはずだが、合計が期待値と合わない。

### 起動

```bash
cd /home/rira/rira100000000/girb/girb-mcp
rdbg --open --port=12345 --nonstop -- examples/01_simple_bug.rb
```

### Claude Codeへの指示例

> ポート12345のデバッグセッションに接続して、Cartクラスの割引計算にバグがあるようです。原因を調査してください。

**期待される調査の流れ:**
1. `connect` でセッションに接続
2. `get_context` で現在の状態を確認
3. `evaluate_code` で `cart.subtotal`, `cart.discount_rate`, `cart.total` を評価
4. `get_source` で `Cart#total` のソースを確認
5. `sub + discount` が `sub - discount` であるべきと気づく

---

## シナリオ2: データパイプラインのデータ消失を追跡

**ファイル:** `examples/02_data_pipeline.rb`

**背景:** CSVデータを処理するパイプラインで、5件中2件のレコードが「不正」として除外される。`nil.to_i` が `0` を返すことで、年齢やスコアが未入力のレコードがバリデーションで弾かれている。

### 起動

```bash
rdbg --open --port=12345 --nonstop -- examples/02_data_pipeline.rb
```

### Claude Codeへの指示例

> ポート12345に接続してください。CSVデータ処理パイプラインで一部のレコードが消えているようです。parseからvalidateの各段階でデータがどう変わるか、ステップ実行で追跡してください。

**期待される調査の流れ:**
1. `connect` で接続
2. `set_breakpoint` で `parse` メソッドの後にブレークポイント設置
3. `evaluate_code` で `@records` を確認 → age=0, score=0 のレコードがある
4. `set_breakpoint` で `validate` メソッド内にブレークポイント設置
5. `step` / `next` でどのレコードがrejectされるか確認
6. `nil.to_i` が原因と特定

---

## シナリオ3: 木構造の探索を観察

**ファイル:** `examples/03_recursion.rb`

**背景:** 組織図（木構造）を構築し、探索する。再帰的な処理の動きを観察する。

### 起動

```bash
rdbg --open --port=12345 --nonstop -- examples/03_recursion.rb
```

### Claude Codeへの指示例

> ポート12345に接続して、組織図の木構造を調査してください。全体のノード数、最大深度を確認し、"Engineer 3"を検索する際のfindメソッドの動きを追跡してください。

**期待される調査の流れ:**
1. `connect` で接続
2. `evaluate_code` で `company.to_s` → 組織図全体を表示
3. `evaluate_code` で `company.total_nodes`, `company.max_depth` を確認
4. `set_breakpoint` で `TreeNode#find` にブレークポイント設置（条件: `target == "Engineer 3"`）
5. `continue_execution` → findの再帰呼び出しを観察
6. `get_context` で各フレームの `value`, `target` を確認

---

## シナリオ4: run_scriptでスクリプトを直接起動

`run_script` ツールを使って、ターミナルで事前にrdbgを起動せずにClaude Codeだけで完結するパターン。

### Claude Codeへの指示例

> examples/01_simple_bug.rb をデバッガ付きで起動して、バグの原因を調査してください。

**期待される流れ:**
1. `run_script(file: "examples/01_simple_bug.rb")` でスクリプト起動＆接続
2. 自動的にdebugger文で停止
3. 以降はシナリオ1と同様の調査

---

## 共通のツール使い方ヒント

| やりたいこと | ツール | 例 |
|---|---|---|
| 変数の値を見る | `evaluate_code` | `evaluate_code(code: "user.name")` |
| オブジェクトの詳細 | `inspect_object` | `inspect_object(expression: "cart")` |
| 全変数を一覧 | `get_context` | `get_context()` |
| メソッドのソースを読む | `get_source` | `get_source(target: "Cart#total")` |
| 次の行へ | `next` | `next()` |
| メソッドの中へ | `step` | `step()` |
| ブレークポイント設定 | `set_breakpoint` | `set_breakpoint(file: "example.rb", line: 10)` |
| 条件付きブレークポイント | `set_breakpoint` | `set_breakpoint(file: "example.rb", line: 10, condition: "x > 5")` |
| 実行再開 | `continue_execution` | `continue_execution()` |
| 任意のデバッガコマンド | `run_debug_command` | `run_debug_command(command: "info threads")` |

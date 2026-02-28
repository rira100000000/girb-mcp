# girb-mcp

LLMエージェントが実行中のRubyプロセスの実行時コンテキストにアクセスするためのMCP (Model Context Protocol) サーバーです。

Claude CodeなどのLLMエージェントが、停止中のRubyプロセスに接続し、変数の調査・コード評価・ブレークポイント設定・実行制御をMCPツール呼び出しだけで完結できます。

## できること

既存のRuby/Rails向けMCPサーバーは静的解析やアプリケーションレベルのAPIにとどまっています。girb-mcpはdebug gem経由で**実行中のRubyプロセス**に接続し、その実行時状態をLLMエージェントに公開します。

```
Claude Code → connect(host: "localhost", port: 12345)
Claude Code → get_context()
  → ローカル変数、インスタンス変数、コールスタック
Claude Code → evaluate_code(code: "user.valid?")
  → false
Claude Code → evaluate_code(code: "user.errors.full_messages")
  → ["Email can't be blank"]
Claude Code → continue_execution()
```

## インストール

```ruby
gem "girb-mcp"
```

または直接インストール：

```
gem install girb-mcp
```

Ruby >= 3.2.0が必要です。

## クイックスタート

### 1. デバッガ付きでRubyプロセスを起動

```bash
# スクリプト
rdbg --open --port=12345 my_script.rb

# 環境変数で指定
RUBY_DEBUG_OPEN=true RUBY_DEBUG_PORT=12345 ruby my_script.rb

# コード中に `debugger` / `binding.break` を記述して実行
rdbg --open my_script.rb
```

### 2. Claude Codeの設定

`~/.claude/settings.json`（またはプロジェクトの`.claude/settings.json`）に追加：

```json
{
  "mcpServers": {
    "girb-mcp": {
      "command": "girb-mcp",
      "args": []
    }
  }
}
```

Bundler経由の場合：

```json
{
  "mcpServers": {
    "girb-mcp": {
      "command": "bundle",
      "args": ["exec", "girb-mcp"]
    }
  }
}
```

### 3. Claude Codeでデバッグ

Claude Codeに接続とデバッグを依頼：

> 「ポート12345のデバッグセッションに接続して現在の状態を見せて」

> 「app/models/user.rbの42行目にブレークポイントを設定して、/users/1にGETリクエストを送って」

## 使い方

```
Usage: girb-mcp [options]
    -t, --transport TRANSPORT        トランスポート: stdio（デフォルト）または http
    -p, --port PORT                  HTTPポート（デフォルト: 6029、httpトランスポート時のみ）
        --host HOST                  HTTPホスト（デフォルト: 127.0.0.1、httpトランスポート時のみ）
        --session-timeout SECONDS    セッションタイムアウト秒数（デフォルト: 1800）
    -v, --version                    バージョン表示
    -h, --help                       ヘルプ表示
```

### STDIOトランスポート（デフォルト）

Claude Codeなどの標準的なMCPクライアント向け。追加設定は不要です。

```bash
girb-mcp
```

### HTTPトランスポート（Streamable HTTP）

ブラウザベースのクライアントやHTTP対応MCPクライアント向け。

```bash
girb-mcp --transport http --port 8080
```

MCPエンドポイントは `http://127.0.0.1:8080/mcp` で利用可能になります。

### セッションタイムアウト

デバッグセッションは30分間操作がないと自動的にクリーンアップされます。変更するには：

```bash
girb-mcp --session-timeout 3600  # 1時間
```

セッションマネージャーは、対象プロセスが終了したセッションも検出して自動的にクリーンアップします。

## ツール一覧

### 接続・検出

| ツール | 説明 |
|------|------|
| `list_debug_sessions` | 利用可能なデバッグセッション一覧（Unixソケット） |
| `connect` | ソケットパスまたはTCPでデバッグセッションに接続 |
| `list_paused_sessions` | 接続中のセッション一覧 |

### 調査

| ツール | 説明 |
|------|------|
| `evaluate_code` | 停止中のbindingでRubyコードを実行 |
| `inspect_object` | オブジェクトのクラス・値・インスタンス変数を取得 |
| `get_context` | ローカル変数・インスタンス変数・コールスタック・ブレークポイントを一括取得 |
| `get_source` | メソッドまたはクラスのソースコードを取得 |
| `read_file` | ソースファイルの読み取り（行範囲指定可） |
| `list_files` | ディレクトリ内のファイル一覧（globパターンでフィルタ可） |

### 実行制御

| ツール | 説明 |
|------|------|
| `set_breakpoint` | ブレークポイント設定：行（file + line）、メソッド（`User#save`）、例外クラス |
| `remove_breakpoint` | file + line、メソッド名、例外クラス、または番号でブレークポイントを削除 |
| `continue_execution` | 次のブレークポイントまたは終了まで実行を再開 |
| `step` | ステップイン（メソッド呼び出しに入る） |
| `next` | ステップオーバー（次の行へ進む） |
| `finish` | 現在のメソッド/ブロックがreturnするまで実行 |
| `run_debug_command` | 任意のデバッガコマンドを直接実行 |
| `disconnect` | セッション切断とプロセス終了 |

### 入口ツール

| ツール | 説明 |
|------|------|
| `run_script` | rdbg経由でRubyスクリプトを起動して接続 |
| `trigger_request` | デバッグ中のRailsアプリにHTTPリクエストを送信 |

### Railsツール（自動検出）

Railsプロセスを検出すると自動的に登録されます。

| ツール | 説明 |
|------|------|
| `rails_info` | アプリ名・Rails/Rubyバージョン・環境・ルートパスを表示 |
| `rails_routes` | ルーティング一覧（verb, path, controller#action）、コントローラ・パスでフィルタ可能 |
| `rails_model` | モデル構造：カラム・アソシエーション・バリデーション・enum・スコープを表示 |

## ワークフロー例

### Rubyスクリプトのデバッグ

```
Agent: run_script(file: "my_script.rb")
Agent: get_context()
Agent: evaluate_code(code: "result")
Agent: next()
Agent: evaluate_code(code: "result")
Agent: continue_execution()
```

### メソッドブレークポイント

```
Agent: run_script(file: "my_script.rb", breakpoints: ["DataPipeline#validate"])
  → スクリプトが起動し、DataPipeline#validate で停止
Agent: evaluate_code(code: "records")
Agent: continue_execution()
```

### 例外のキャッチとデバッグ

```
Agent: run_script(file: "my_script.rb")
Agent: set_breakpoint(exception_class: "NoMethodError")
Agent: continue_execution()
  → 例外が伝播する前に実行が停止
Agent: get_context()
Agent: evaluate_code(code: "$!.message")
```

### クラッシュ後の再起動

```
  → NoMethodError でプログラムがクラッシュ
Agent: run_script(file: "my_script.rb", restore_breakpoints: true)
  → 前回のブレークポイントが自動復元
Agent: set_breakpoint(exception_class: "NoMethodError")
Agent: continue_execution()
  → クラッシュ前に例外をキャッチ
```

### Railsリクエストのデバッグ

`girb-rails` でデバッグ有効状態のRailsサーバーを起動：

```bash
girb-rails                # RUBY_DEBUG_OPEN=true bin/rails server と同等
girb-rails s -p 4000      # ポート指定
girb-rails --debug-port 3333  # TCPデバッグポートを指定（Docker内で便利）
```

エージェントにデバッグを依頼：

```
Agent: connect()
Agent: set_breakpoint(file: "app/controllers/users_controller.rb", line: 15)
Agent: trigger_request(method: "GET", url: "http://localhost:3000/users/1")
Agent: get_context()
Agent: evaluate_code(code: "@user.attributes")
Agent: continue_execution()
```

### Docker内のRailsアプリをデバッグ

**1. 対象アプリの設定**

`docker-compose.yml` にデバッグ用の環境変数を設定：

```yaml
services:
  web:
    build: .
    ports:
      - "3000:3000"    # Rails
      - "12345:12345"  # デバッグ
    environment:
      - RUBY_DEBUG_OPEN=true
      - RUBY_DEBUG_HOST=0.0.0.0
      - RUBY_DEBUG_PORT=12345
```

`RUBY_DEBUG_HOST=0.0.0.0` はコンテナ内で全インターフェースからの接続を受け付けるために必要です。

**2. 接続してデバッグ**

```
Agent: connect(host: "localhost", port: 12345)
Agent: set_breakpoint(file: "app/controllers/users_controller.rb", line: 15)
Agent: trigger_request(method: "GET", url: "http://localhost:3000/users/1")
Agent: get_context()
Agent: evaluate_code(code: "@user.attributes")
Agent: continue_execution()
```

TCP経由で接続すると、`read_file` と `list_files` は自動的にデバッグセッション経由で動作するため、ローカルにソースコードがなくてもコンテナ内のファイルを閲覧・読み取りできます。

### 既存のブレークポイントに接続

```bash
# ターミナル: アプリが `debugger` 文に到達
rdbg --open my_app.rb
```

```
Agent: list_debug_sessions()
Agent: connect(path: "/tmp/rdbg-1000/rdbg-12345")
Agent: get_context()
Agent: evaluate_code(code: "local_variables.map { |v| [v, binding.local_variable_get(v)] }.to_h")
```

## 仕組み

```
┌─────────────┐ STDIO or Streamable HTTP ┌───────────┐    TCP/Unixソケット   ┌──────────────┐
│ Claude Code  │ ◄──────────────────────► │ girb-mcp  │ ◄──────────────────► │ Rubyプロセス  │
│ (MCPクライアント)│       (JSON-RPC)         │(MCPサーバー) │  debug gemプロトコル  │  (rdbg)      │
└─────────────┘                           └───────────┘                      └──────────────┘
```

1. girb-mcpはSTDIO（デフォルト）またはStreamable HTTPで通信するMCPサーバーとして動作
2. debug gem（`rdbg --open`）が対象Rubyプロセスにソケットを公開
3. girb-mcpがdebug gemのワイヤープロトコルでそのソケットに接続
4. MCPツール呼び出しがデバッガコマンドに変換され、結果が返される
5. アイドル状態のセッションは設定可能なタイムアウト後に自動クリーンアップされる

## girbファミリー

girb-mcpは[girb](https://github.com/rira100000000/girb)ファミリーの一員です：

- **girb** — AI搭載IRBアシスタント（対話型、人間向け）
- **girb-mcp** — LLMエージェント向けMCPサーバー（プログラマティック、エージェント向け）
- **girb-ruby_llm** — ruby_llm経由のLLMプロバイダー
- **girb-gemini** — Gemini API経由のLLMプロバイダー

## 開発

```bash
git clone https://github.com/rira100000000/girb-mcp.git
cd girb-mcp
bundle install
```

## ライセンス

MIT

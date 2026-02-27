# Rails Test App for girb-mcp

girb-mcpの動作検証用Railsアプリケーション。ローカルでもDockerでも実行可能。

## ローカル実行

```bash
bundle install
bin/rails db:prepare
RUBY_DEBUG_OPEN=true bin/rails server
```

girb-mcpから接続:
```
connect          # Unix socketで自動検出
```

## Docker実行

```bash
docker compose up --build
```

起動確認:
```bash
curl http://localhost:3000/health
```

girb-mcpから接続:
```
connect(host: "localhost", port: 12345)
```

### Dockerデバッグの流れ

接続するとtrap context（Pumaのシグナルハンドラ内）で停止します。
DB操作やモデルのautoloadingは使えないため、ブレークポイント経由で通常コンテキストに移行します:

```
1. set_breakpoint(file: "app/controllers/users_controller.rb", line: 5)
2. trigger_request(method: "GET", url: "http://localhost:3000/users")
3. # ブレークポイントにヒット → evaluate_code, get_context 等が使える
4. continue_execution  # リクエスト完了
```

停止:
```bash
docker compose down
```

## エンドポイント

| メソッド | パス | 説明 |
|---------|------|------|
| GET | /health | ヘルスチェック |
| GET | /users | ユーザー一覧 |
| GET | /users/:id | ユーザー詳細 |
| GET | /posts | 投稿一覧 |
| GET | /orders | 注文一覧 |
| GET | /dashboard | ダッシュボード(HTML) |

## シードデータ

- ユーザー4人 (Alice/admin, Bob/editor, Carol/member, Dave/guest)
- 投稿4件、コメント4件、注文6件

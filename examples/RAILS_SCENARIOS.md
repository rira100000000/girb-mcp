# girb-mcp Rails デバッグシナリオ

## 準備

### 1. テスト用Railsアプリのセットアップ

```bash
cd /home/rira/rira100000000/girb/girb-mcp/examples/rails_test_app
bash setup.sh
```

User（admin/editor/member/guest、バリデーション、enum）、Post（published/draft/archived、スコープ）、Comment を持つブログアプリが生成される。

### 2. Railsサーバーの起動

```bash
cd examples/rails_test_app/testapp
RUBY_DEBUG_OPEN=true bin/rails server -p 3999
```

`RUBY_DEBUG_OPEN=true` により、debug gem がソケットを開いた状態で起動する。

### 3. girb-mcp の設定

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

## シナリオ5: rails_info でアプリ概要を把握

**テスト対象:** `rails_info`

**背景:** 初めてRailsプロセスに接続した後、まずアプリケーションの基本情報を確認する。

### Claude Codeへの指示例

> Railsサーバーのデバッグセッションに接続して、アプリケーションの概要を教えてください。

### 期待される流れ

1. `connect` → Railsプロセスに接続
2. `rails_info` → アプリ概要を表示

### 確認ポイント

- [ ] アプリ名が表示される（TestappなどRailsが生成する名前）
- [ ] Railsバージョンが正しく表示される（例: 7.1.x）
- [ ] 環境が `development` と表示される
- [ ] Rubyバージョンが表示される
- [ ] `Root:` にアプリのパスが表示される
- [ ] Database セクションに `adapter: sqlite3` が表示される
- [ ] パスワード等のセンシティブ情報が `[FILTERED]` でマスクされる

### 失敗パターンのテスト

- 非Railsプロセス（例: `run_script` で普通のRubyスクリプト起動）に対して `rails_info` → `Not a Rails application` エラー

---

## シナリオ6: rails_routes でルーティングを確認

**テスト対象:** `rails_routes`

**背景:** コントローラアクションにブレークポイントを設定する前に、利用可能なルートを確認する。

### Claude Codeへの指示例

> このRailsアプリのルーティングを教えてください。usersコントローラのルートだけ見せてください。

### 期待される流れ

1. `rails_routes` → 全ルート表示
2. `rails_routes(controller: "users")` → usersのみフィルタ
3. `rails_routes(path: "/login")` → パスでフィルタ

### 確認ポイント

- [ ] 全ルート表示で以下が含まれる:
  - `GET /users users#index`
  - `POST /users users#create`
  - `GET /users/:id users#show`
  - `POST /login sessions#create`
  - `GET /health health#show`
  - `GET /dashboard dashboard#index`
  - `GET /posts/search posts#search`
- [ ] `controller: "users"` フィルタでusers関連のルートのみ表示される
- [ ] `controller: "sessions"` フィルタで login/me/logout が表示される
- [ ] `path: "/posts"` フィルタでposts関連ルートが表示される
- [ ] `Total: N routes` が正しいカウントを表示する
- [ ] ルート名（`users`, `user` 等）がカッコ内に表示される

---

## シナリオ7: rails_model でモデル構造を確認

**テスト対象:** `rails_model`

**背景:** デバッグ中にモデルの構造（カラム、アソシエーション、バリデーション）を把握する。

### Claude Codeへの指示例

> User モデルの構造を教えてください。Post モデルも確認してください。

### 期待される流れ

1. `rails_model(model_name: "User")` → User の全情報
2. `rails_model(model_name: "Post")` → Post の全情報
3. `rails_model(model_name: "Nonexistent")` → エラー

### 確認ポイント（User モデル）

- [ ] ヘッダー: `=== User (table: users) ===`
- [ ] Columns セクション:
  - `id` (integer, NOT NULL, PK)
  - `name` (string)
  - `email` (string)
  - `role` (integer) — default: 0 が表示されるかもしれない
  - `active` (boolean)
  - `created_at`, `updated_at`
- [ ] Associations セクション:
  - `has_many :posts -> Post`
  - `has_many :comments -> Comment`
- [ ] Validations セクション:
  - `presence [:name, :email]`
  - `uniqueness [:email]`
  - `length [:name, ...]`
  - `format [:email]`
- [ ] Enums セクション:
  - `role: { guest: 0, member: 1, editor: 2, admin: 3 }`
- [ ] Scopes セクション（検出される場合）:
  - `active`, `admins`, `recent`

### 確認ポイント（Post モデル）

- [ ] `belongs_to :user -> User`
- [ ] `has_many :comments -> Comment`
- [ ] enum `status: { draft: 0, published: 1, archived: 2 }`
- [ ] scope: `published`, `drafts`, `recent`

### エラーパターン

- [ ] `rails_model(model_name: "Nonexistent")` → `Model Nonexistent not found`
- [ ] `rails_model(model_name: "String")` → `String is not an ActiveRecord model`

---

## シナリオ8: trigger_request の CSRF 自動スキップ

**テスト対象:** `trigger_request` のCSRF自動無効化

**背景:** RailsではPOST/PUT/PATCH/DELETEリクエストにCSRFトークンが必要。girb-mcpはこれを自動的に回避する。

### Claude Codeへの指示例

> POST /users で新しいユーザーを作成してください。名前は「テスト太郎」、メールは「taro@test.com」、roleはmemberです。

### 期待される流れ

1. `trigger_request(method: "POST", url: "http://localhost:3999/users", body: '{"name":"テスト太郎","email":"taro@test.com","role":"member","active":true}')`
2. CSRFが自動的に無効化され、リクエスト成功
3. レスポンスにJSON（作成されたユーザー情報）が整形表示される

### 確認ポイント

- [ ] CSRFエラー（`422 Unprocessable Entity` + `Can't verify CSRF token`）にならない
- [ ] `201 Created` のステータスが返る
- [ ] JSONレスポンスがpretty-printされる
- [ ] Content-Typeが自動的に `application/json` に設定される（bodyが `{` で始まるため）
- [ ] リクエスト後にCSRF保護が復元される（後続の通常リクエストに影響しない）

### 追加テスト

```
# skip_csrf: false を指定 → CSRFエラーが発生するはず
trigger_request(method: "POST", url: "http://localhost:3999/users",
  body: '{"name":"test","email":"test@test.com"}', skip_csrf: false)
```

- [ ] `422` エラーまたはCSRF関連エラーが返る

---

## シナリオ9: trigger_request の Cookie とセッション管理

**テスト対象:** `trigger_request` のCookie管理

**背景:** ログインしてセッションCookieを取得し、認証済みリクエストを送信する。

### Claude Codeへの指示例

> alice@example.com でログインして、セッション情報を確認してください。

### 期待される流れ

1. `trigger_request(method: "POST", url: "http://localhost:3999/login", body: '{"email":"alice@example.com"}')`
   → ログイン成功、`Set-Cookie` ヘッダーが表示される
2. レスポンスからセッションCookie値を取得
3. `trigger_request(method: "GET", url: "http://localhost:3999/me", cookies: {"_session_id": "<取得した値>"})`
   → ログイン済みのユーザー情報が返る

### 確認ポイント

- [ ] ログインレスポンスに `Set-Cookie:` が表示される
- [ ] `cookies` パラメータでCookieを送信できる
- [ ] `/me` エンドポイントでログイン状態が確認できる
- [ ] `DELETE /logout` でログアウトできる

---

## シナリオ10: trigger_request のレスポンス整形

**テスト対象:** JSON整形、HTML切り詰め、リダイレクト表示

### テストケース一覧

#### 10a. JSON レスポンスの整形

```
trigger_request(method: "GET", url: "http://localhost:3999/health")
```

- [ ] JSONがインデント付きで整形表示される
- [ ] `HTTP 200 OK` ステータス表示

#### 10b. HTML レスポンスの切り詰め

```
trigger_request(method: "GET", url: "http://localhost:3999/dashboard")
```

- [ ] HTMLがそのまま表示される（1000文字以下の場合）
- [ ] 大きいHTMLの場合 `... (HTML truncated, N bytes total)` と表示される

#### 10c. Content-Type 自動検出

```
# JSON body → Content-Type: application/json
trigger_request(method: "POST", url: "http://localhost:3999/users",
  body: '{"name":"test","email":"auto@test.com"}')

# form body → Content-Type: application/x-www-form-urlencoded
trigger_request(method: "POST", url: "http://localhost:3999/users",
  body: "name=test&email=form@test.com")
```

- [ ] JSON bodyの場合、Content-Typeが `application/json` になる
- [ ] form bodyの場合、Content-Typeが `application/x-www-form-urlencoded` になる

#### 10d. 空レスポンス

```
trigger_request(method: "DELETE", url: "http://localhost:3999/users/1")
```

- [ ] `204 No Content` + `(empty body)` と表示される

#### 10e. バリデーションエラー

```
trigger_request(method: "POST", url: "http://localhost:3999/users",
  body: '{"name":"","email":"invalid"}')
```

- [ ] `422 Unprocessable Entity` ステータス
- [ ] エラーメッセージが整形表示される

---

## シナリオ11: ブレークポイント + trigger_request でコントローラをデバッグ

**テスト対象:** Rails デバッグの統合ワークフロー

**背景:** N+1クエリ問題があるPosts#searchアクションをデバッグする。

### Claude Codeへの指示例

> `/posts/search?q=Rails` のリクエストをデバッグしたいです。PostsControllerのsearchアクションにブレークポイントを設定して、N+1問題を調査してください。

### 期待される流れ

1. `connect` → Railsプロセスに接続
2. `rails_routes(controller: "posts")` → search のルートを確認
3. `rails_model(model_name: "Post")` → Post のアソシエーションを確認
4. `set_breakpoint(file: "app/controllers/posts_controller.rb", line: ...)` → searchアクション内にBP設置
5. `trigger_request(method: "GET", url: "http://localhost:3999/posts/search?q=Rails")`
6. ブレークポイントでヒット
7. `get_context` → ローカル変数を確認
8. `evaluate_code(code: "@posts.to_sql")` → SQLを確認
9. `next` でステップ実行しながら N+1 を観察
10. `evaluate_code(code: "post.user")` → 個別クエリが発行されることを確認

### 確認ポイント

- [ ] ブレークポイントが正しくヒットする
- [ ] `get_context` でコントローラ内の変数が見える
- [ ] `evaluate_code` でActiveRecordのメソッドが実行できる
- [ ] `next` でアクション内をステップ実行できる
- [ ] デバッグ完了後 `continue_execution` で残りのリクエストが処理される

---

## シナリオ12: rails_info → rails_routes → rails_model の連携

**テスト対象:** Railsツールの総合テスト

**背景:** 見知らぬRailsアプリに接続して、全体像を素早く把握する。

### Claude Codeへの指示例

> このRailsアプリの全体像を教えてください。どんなモデルがあって、どんなAPIエンドポイントがあるか調べてください。

### 期待される流れ

1. `connect` → 接続
2. `rails_info` → アプリ名、Rails/Ruby版、DB情報
3. `rails_routes` → 全ルート → コントローラ名からモデルを推測
4. `rails_model(model_name: "User")` → User構造
5. `rails_model(model_name: "Post")` → Post構造
6. `rails_model(model_name: "Comment")` → Comment構造
7. まとめを報告

### 確認ポイント

- [ ] 3つのRailsツールがエラーなく順次実行できる
- [ ] 各ツールの出力が一貫性を持つ（モデル間のアソシエーション名が対応する等）
- [ ] rails_model で User に `has_many :posts` があり、Post に `belongs_to :user` がある

---

## 共通ツール使い方ヒント（Rails向け追加分）

| やりたいこと | ツール | 例 |
|---|---|---|
| アプリ概要を見る | `rails_info` | `rails_info()` |
| ルーティング確認 | `rails_routes` | `rails_routes(controller: "users")` |
| モデル構造を見る | `rails_model` | `rails_model(model_name: "User")` |
| HTTPリクエスト送信 | `trigger_request` | `trigger_request(method: "GET", url: "http://localhost:3999/users")` |
| JSONをPOST | `trigger_request` | `trigger_request(method: "POST", url: "...", body: '{"key":"value"}')` |
| Cookie付きリクエスト | `trigger_request` | `trigger_request(method: "GET", url: "...", cookies: {"key": "val"})` |
| CSRF明示制御 | `trigger_request` | `trigger_request(method: "POST", ..., skip_csrf: true)` |

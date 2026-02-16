#!/bin/bash
# girb-mcp Rails テスト用アプリのセットアップスクリプト
#
# 使い方:
#   cd examples/rails_test_app
#   bash setup.sh
#
# これにより、girb-mcpのRailsツールをテストするための
# 最小限のRailsアプリケーションが生成されます。

set -e

APP_DIR="$(cd "$(dirname "$0")" && pwd)/testapp"

echo "=== girb-mcp Rails テストアプリ セットアップ ==="
echo ""

# 既存のアプリがあれば確認
if [ -d "$APP_DIR" ]; then
  echo "既存のテストアプリが見つかりました: $APP_DIR"
  read -p "削除して再作成しますか？ (y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "中止しました。"
    exit 0
  fi
  rm -rf "$APP_DIR"
fi

echo "1/6: Rails アプリを生成中..."
rails new "$APP_DIR" \
  --database=sqlite3 \
  --skip-git \
  --skip-docker \
  --skip-action-mailer \
  --skip-action-mailbox \
  --skip-action-text \
  --skip-active-storage \
  --skip-action-cable \
  --skip-hotwire \
  --skip-jbuilder \
  --skip-test \
  --skip-system-test \
  --skip-bootsnap \
  --skip-asset-pipeline \
  --skip-javascript \
  --minimal \
  --quiet

cd "$APP_DIR"

# debug gem を追加
echo "" >> Gemfile
echo '# girb-mcp テスト用' >> Gemfile
echo 'gem "debug"' >> Gemfile
bundle install --quiet

echo "2/6: モデルを生成中..."

# User モデル: バリデーション、enum、アソシエーション
bin/rails generate model User \
  name:string \
  email:string \
  role:integer \
  active:boolean \
  --quiet --no-test-framework

# Post モデル: belongs_to、スコープ
bin/rails generate model Post \
  title:string \
  body:text \
  status:integer \
  user:references \
  published_at:datetime \
  --quiet --no-test-framework

# Comment モデル: ポリモーフィック的な関連
bin/rails generate model Comment \
  body:text \
  user:references \
  post:references \
  --quiet --no-test-framework

echo "3/6: モデルコードを設定中..."

# User モデル
cat > app/models/user.rb << 'RUBY'
class User < ApplicationRecord
  has_many :posts, dependent: :destroy
  has_many :comments, dependent: :destroy

  validates :name, presence: true, length: { maximum: 50 }
  validates :email, presence: true, uniqueness: true,
            format: { with: /\A[^@\s]+@[^@\s]+\z/ }

  enum :role, { guest: 0, member: 1, editor: 2, admin: 3 }

  scope :active, -> { where(active: true) }
  scope :admins, -> { where(role: :admin) }
  scope :recent, -> { order(created_at: :desc) }

  def display_name
    "#{name} (#{role})"
  end
end
RUBY

# Post モデル
cat > app/models/post.rb << 'RUBY'
class Post < ApplicationRecord
  belongs_to :user
  has_many :comments, dependent: :destroy

  validates :title, presence: true, length: { maximum: 100 }
  validates :body, presence: true

  enum :status, { draft: 0, published: 1, archived: 2 }

  scope :published, -> { where(status: :published) }
  scope :drafts, -> { where(status: :draft) }
  scope :recent, -> { order(published_at: :desc) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }

  def summary
    body.to_s.truncate(100)
  end
end
RUBY

# Comment モデル
cat > app/models/comment.rb << 'RUBY'
class Comment < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :body, presence: true, length: { minimum: 3 }

  scope :recent, -> { order(created_at: :desc) }
end
RUBY

echo "4/6: コントローラとルーティングを設定中..."

# UsersController
mkdir -p app/controllers
cat > app/controllers/users_controller.rb << 'RUBY'
class UsersController < ApplicationController
  before_action :set_user, only: [:show, :update, :destroy]

  def index
    @users = User.all
    render json: @users
  end

  def show
    render json: @user.as_json(include: { posts: { only: [:id, :title, :status] } })
  end

  def create
    @user = User.new(user_params)
    if @user.save
      render json: @user, status: :created
    else
      render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @user.update(user_params)
      render json: @user
    else
      render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @user.destroy
    head :no_content
  end

  private

  def set_user
    @user = User.find(params[:id])
  end

  def user_params
    params.permit(:name, :email, :role, :active)
  end
end
RUBY

# PostsController
cat > app/controllers/posts_controller.rb << 'RUBY'
class PostsController < ApplicationController
  before_action :set_post, only: [:show, :update]

  def index
    @posts = Post.published.includes(:user).recent
    render json: @posts.as_json(include: { user: { only: [:id, :name] } })
  end

  def show
    render json: @post.as_json(
      include: {
        user: { only: [:id, :name] },
        comments: { include: { user: { only: [:id, :name] } } }
      }
    )
  end

  def create
    @post = Post.new(post_params)
    if @post.save
      render json: @post, status: :created
    else
      render json: { errors: @post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @post.update(post_params)
      render json: @post
    else
      render json: { errors: @post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # 検索エンドポイント（デバッグ向け：N+1問題あり）
  def search
    query = params[:q].to_s
    @posts = Post.where("title LIKE ?", "%#{query}%")

    # 意図的なN+1（デバッグで発見させる）
    results = @posts.map do |post|
      {
        id: post.id,
        title: post.title,
        author: post.user.name,
        comments_count: post.comments.count
      }
    end

    render json: results
  end

  private

  def set_post
    @post = Post.find(params[:id])
  end

  def post_params
    params.permit(:title, :body, :status, :user_id, :published_at)
  end
end
RUBY

# SessionsController（Cookie テスト用）
cat > app/controllers/sessions_controller.rb << 'RUBY'
class SessionsController < ApplicationController
  def create
    user = User.find_by(email: params[:email])
    if user
      session[:user_id] = user.id
      render json: { message: "Logged in", user: user.as_json(only: [:id, :name, :email, :role]) }
    else
      render json: { error: "Invalid email" }, status: :unauthorized
    end
  end

  def show
    if session[:user_id]
      user = User.find(session[:user_id])
      render json: { logged_in: true, user: user.as_json(only: [:id, :name, :email, :role]) }
    else
      render json: { logged_in: false }
    end
  end

  def destroy
    session.delete(:user_id)
    render json: { message: "Logged out" }
  end
end
RUBY

# HealthController（シンプルなテスト用）
cat > app/controllers/health_controller.rb << 'RUBY'
class HealthController < ApplicationController
  def show
    render json: {
      status: "ok",
      rails_version: Rails::VERSION::STRING,
      ruby_version: RUBY_VERSION,
      environment: Rails.env,
      time: Time.current.iso8601
    }
  end
end
RUBY

# DashboardController（HTMLレスポンス テスト用）
cat > app/controllers/dashboard_controller.rb << 'RUBY'
class DashboardController < ApplicationController
  def index
    @stats = {
      users: User.count,
      posts: Post.count,
      comments: Comment.count,
      published_posts: Post.published.count
    }

    render html: <<~HTML.html_safe
      <!DOCTYPE html>
      <html>
      <head><title>Dashboard</title></head>
      <body>
        <h1>Dashboard</h1>
        <ul>
          <li>Users: #{@stats[:users]}</li>
          <li>Posts: #{@stats[:posts]}</li>
          <li>Comments: #{@stats[:comments]}</li>
          <li>Published: #{@stats[:published_posts]}</li>
        </ul>
      </body>
      </html>
    HTML
  end
end
RUBY

# ルーティング
cat > config/routes.rb << 'RUBY'
Rails.application.routes.draw do
  resources :users, only: [:index, :show, :create, :update, :destroy]

  resources :posts, only: [:index, :show, :create, :update] do
    collection do
      get :search
    end
  end

  # セッション管理
  post   "/login",  to: "sessions#create"
  get    "/me",     to: "sessions#show"
  delete "/logout", to: "sessions#destroy"

  # ヘルスチェック
  get "/health", to: "health#show"

  # ダッシュボード（HTML）
  get "/dashboard", to: "dashboard#index"

  # ルートパス
  root "health#show"
end
RUBY

echo "5/6: データベースをセットアップ中..."

bin/rails db:create db:migrate --quiet

# シードデータ
cat > db/seeds.rb << 'RUBY'
puts "シードデータを作成中..."

# ユーザー
alice = User.create!(name: "Alice", email: "alice@example.com", role: :admin, active: true)
bob   = User.create!(name: "Bob",   email: "bob@example.com",   role: :editor, active: true)
carol = User.create!(name: "Carol", email: "carol@example.com", role: :member, active: true)
dave  = User.create!(name: "Dave",  email: "dave@example.com",  role: :guest, active: false)

# 投稿
post1 = Post.create!(
  title: "Rails デバッグ入門",
  body: "debug gemを使ったRailsアプリケーションのデバッグ方法について解説します。breakpointの設定、変数の確認、ステップ実行など基本的なデバッグ技法を紹介します。",
  status: :published,
  user: alice,
  published_at: 2.days.ago
)

post2 = Post.create!(
  title: "ActiveRecordのN+1問題を解決する",
  body: "includesやpreloadを使ってN+1クエリを解消する方法を紹介します。BulletやProsopiteなどの検出ツールも併せて解説します。",
  status: :published,
  user: bob,
  published_at: 1.day.ago
)

post3 = Post.create!(
  title: "下書き: テスト駆動開発のすすめ",
  body: "RSpecを使ったTDDの実践方法について。まだ書きかけです。",
  status: :draft,
  user: alice
)

post4 = Post.create!(
  title: "アーカイブ済み: 古い記事",
  body: "この記事はアーカイブされました。",
  status: :archived,
  user: carol
)

# コメント
Comment.create!(body: "とても分かりやすい記事です！", user: bob, post: post1)
Comment.create!(body: "binding.breakの使い方も知りたいです。", user: carol, post: post1)
Comment.create!(body: "N+1問題に困っていたので助かりました。", user: alice, post: post2)
Comment.create!(body: "Bulletの設定方法をもう少し詳しく書いてほしいです。", user: dave, post: post2)

puts "完了: ユーザー#{User.count}人、投稿#{Post.count}件、コメント#{Comment.count}件"
RUBY

bin/rails db:seed

echo "6/6: 動作確認..."

echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "テストアプリの起動方法:"
echo "  cd $APP_DIR"
echo "  RUBY_DEBUG_OPEN=true bin/rails server -p 3999"
echo ""
echo "girb-mcpからの接続:"
echo "  1. connect で Rails プロセスに接続"
echo "  2. rails_info でアプリ概要を確認"
echo "  3. 詳しいシナリオは examples/RAILS_SCENARIOS.md を参照"
echo ""

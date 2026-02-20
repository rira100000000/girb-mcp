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

  # 人気記事の取得
  def trending
    posts = Post.trending
    render json: posts.map { |post|
      {
        id: post.id,
        title: post.title,
        author: post.user.name,
        comments_count: post.comments.size
      }
    }
  end

  # 検索エンドポイント（公開済み記事のみ対象）
  def search
    query = params[:q].to_s
    scope = Post.published

    # ユーザーでフィルタリング
    if params[:user_id].present?
      scope = Post.by_user(params[:user_id])
    end

    scope = scope.where("title LIKE ?", "%#{query}%") if query.present?

    results = scope.map do |post|
      {
        id: post.id,
        title: post.title,
        author: post.user.name,
        status: post.status,
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

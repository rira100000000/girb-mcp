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

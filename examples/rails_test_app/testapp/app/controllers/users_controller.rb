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

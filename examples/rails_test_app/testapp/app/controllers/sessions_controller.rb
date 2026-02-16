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

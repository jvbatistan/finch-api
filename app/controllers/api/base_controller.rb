class Api::BaseController < ActionController::Base
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  include ActionController::Cookies

  protect_from_forgery with: :exception
  respond_to :json

  rescue_from ActionController::InvalidAuthenticityToken, with: :render_invalid_csrf_token

  before_action :reject_inactive_user!

  helper_method :current_data_environment, :real_data_environment?

  private

  def reject_inactive_user!
    return unless current_user && !current_user.active?

    sign_out(:user)
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def render_invalid_csrf_token
    render json: { error: "Token CSRF inválido ou ausente" }, status: :forbidden
  end

  def rotate_csrf_token!
    session.delete(:_csrf_token)
  end

  def current_data_environment
    DataEnvironments.current(request)
  end

  def real_data_environment?
    DataEnvironments.real_data?(request)
  end

  def authenticate_user!
    if user_signed_in?
      super
    else
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def render_not_found
    render json: { error: "Not found" }, status: :not_found
  end
end

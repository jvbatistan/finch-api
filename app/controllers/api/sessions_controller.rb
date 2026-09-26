class Api::SessionsController < Api::BaseController
  def create
    user = User.find_for_authentication(email: params[:email])

    if user&.active? && user.valid_password?(params[:password])
      sign_in(user)
      rotate_csrf_token!
      render json: { ok: true }
    else
      render json: { ok: false, error: "Credenciais inválidas" }, status: :unauthorized
    end
  end

  def destroy
    sign_out(current_user) if user_signed_in?
    render json: { ok: true }
  end
end

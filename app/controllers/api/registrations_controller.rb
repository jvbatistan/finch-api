class Api::RegistrationsController < Api::BaseController
  def create
    if Rails.env.production? || real_data_environment?
      return render json: { error: "Registro público indisponível" }, status: :forbidden
    end

    user = User.new(sign_up_params)

    if user.save
      sign_in(user)
      rotate_csrf_token!
      render json: user_json(user), status: :created
    else
      render json: { error: user.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  private

  def sign_up_params
    params.require(:user).permit(:name, :email, :password, :password_confirmation)
  end

  def user_json(user)
    {
      id: user.id,
      name: user.name,
      email: user.email,
      active: user.active
    }
  end
end

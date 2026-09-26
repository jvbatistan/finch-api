class Api::CsrfController < Api::BaseController
  def show
    response.headers["Cache-Control"] = "no-store"
    render json: { csrf_token: form_authenticity_token }
  end
end

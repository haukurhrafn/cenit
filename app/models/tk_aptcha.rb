class TkAptcha
  include Mongoid::Document
  include Mongoid::Timestamps

  field :token, type: String
  field :email, type: String
  field :code, type: String
  field :count, type: Integer
  field :data, type: Hash

  before_save :ensure_token, :generate_code

  def ensure_token
    self.token = Devise.friendly_token unless token.present?
    true
  end

  def generate_code
    chars = ('a'..'z').to_a
    code = ''
    (Cenit.captcha_length || 5).times { code += chars[rand(chars.length)] }
    self.code = code
    true
  end

  def recode
    generate_code
    save
  end
end
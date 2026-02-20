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

  # NULLロールのユーザーが作られないようにデフォルトを設定
  before_save :ensure_default_role

  def display_name
    "#{name} (#{role})"
  end

  # 管理者のみが他ユーザーの情報を編集可能
  def editable_by?(editor)
    editor.admin? || editor == self
  end

  private

  def ensure_default_role
    # role_before_type_castで内部整数値を確認し、未設定なら初期値を設定
    self.role = :member if role_before_type_cast.nil? || role_before_type_cast.zero?
  end
end

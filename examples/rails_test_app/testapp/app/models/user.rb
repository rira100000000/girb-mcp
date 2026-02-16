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

  def display_name
    "#{name} (#{role})"
  end
end

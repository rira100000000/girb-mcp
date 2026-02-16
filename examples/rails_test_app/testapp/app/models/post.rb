class Post < ApplicationRecord
  belongs_to :user
  has_many :comments, dependent: :destroy

  validates :title, presence: true, length: { maximum: 100 }
  validates :body, presence: true

  enum :status, { draft: 0, published: 1, archived: 2 }

  scope :published, -> { where(status: :published) }
  scope :drafts, -> { where(status: :draft) }
  scope :recent, -> { order(published_at: :desc) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }

  def summary
    body.to_s.truncate(100)
  end
end

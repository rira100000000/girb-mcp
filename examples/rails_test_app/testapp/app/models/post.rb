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

  # コメント数の多い人気記事を取得（パフォーマンス向上のためメモ化）
  def self.trending(limit = 5)
    @trending_posts ||= published
      .left_joins(:comments)
      .group(:id)
      .order("COUNT(comments.id) DESC")
      .limit(limit)
      .includes(:user)
      .to_a
  end

  def summary
    body.to_s.truncate(100)
  end
end

class Comment < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :body, presence: true, length: { minimum: 3 }

  scope :recent, -> { order(created_at: :desc) }
end

class Order < ApplicationRecord
  default_scope { where.not(status: :cancelled) }

  belongs_to :user, optional: true
  has_many :order_items, dependent: :destroy

  enum :status, { cart: 0, pending: 1, completed: 2, cancelled: 3 }

  before_save :recalculate_total
  after_save :archive_items_if_cancelled

  validates :status, presence: true

  scope :completed, -> { where(status: :completed) }

  def self.revenue_stats
    {
      total_revenue: completed.sum(:total_cents),
      average_order: completed.average(:total_cents)&.round || 0,
      order_count: completed.count
    }
  end

  private

  # Scenario 1:
  def recalculate_total
    return if order_items.empty?

    # SQL SUM returns BigDecimal
    subtotal = order_items.sum("quantity * unit_price")

    # Ruby Enumerable#sum with .to_f produces Float
    tax_total = order_items.to_a.sum do |item|
      item.quantity * item.unit_price.to_f * item.tax_rate.to_f
    end

    computed_total = subtotal + tax_total

    if discount_percent.to_f > 0
      computed_total = computed_total * (100 - discount_percent.to_f) / 100
    end

    # Bug: .to_i truncates instead of .round, losing up to 1 cent
    self.total_cents = (computed_total * 100).to_i
  end

  # Scenario 2: zeroes item quantities on cancel
  # This creates a "time bomb": any subsequent save triggers recalculate_total
  # which recomputes total from zero-quantity items, resulting in total_cents = 0
  def archive_items_if_cancelled
    if saved_change_to_status? && cancelled?
      order_items.update_all(quantity: 0)
    end
  end
end

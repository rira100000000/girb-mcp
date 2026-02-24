class OrderItem < ApplicationRecord
  belongs_to :order

  validates :product_name, presence: true
  validates :quantity, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :unit_price, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :tax_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }

  def line_total
    quantity * unit_price
  end

  def tax_amount
    line_total * tax_rate
  end
end

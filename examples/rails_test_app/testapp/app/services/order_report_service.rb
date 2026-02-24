class OrderReportService
  # Scenario 3: silent exception swallowing causes data loss
  # When order.user is nil (deleted user), order.user.name raises NoMethodError
  # The rescue => e catches it and drops the order from the report
  # This causes summary.total_orders != orders.length

  def self.generate
    orders = Order.completed.includes(:user, :order_items)

    report = {
      generated_at: Time.current,
      summary: {
        total_orders: orders.count,
        total_revenue: orders.sum(:total_cents)
      },
      orders: []
    }

    orders.each do |order|
      serialized = serialize_order(order)
      report[:orders] << serialized if serialized
    end

    report
  end

  def self.serialize_order(order)
    {
      id: order.id,
      customer: order.user.name,
      total_cents: order.total_cents,
      items_count: order.order_items.size,
      completed_at: order.completed_at
    }
  rescue => e
    Rails.logger.warn("Failed to serialize order ##{order.id}: #{e.message}")
    nil
  end
  private_class_method :serialize_order
end

class OrdersController < ApplicationController
  # GET /orders
  def index
    @orders = Order.includes(:user, :order_items).order(created_at: :desc)
    render json: @orders.map { |o| order_json(o) }
  end

  # GET /orders/:id
  # Scenario 1: total_cents may be off by 1 cent due to floating point truncation
  def show
    @order = Order.includes(:order_items).find(params[:id])
    render json: order_json(@order).merge(
      items: @order.order_items.map { |item| item_json(item) }
    )
  end

  # POST /orders
  def create
    @order = Order.new(order_params)
    if @order.save
      render json: order_json(@order), status: :created
    else
      render json: { errors: @order.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /orders/:id
  # Scenario 2: updating a cancelled order triggers recalculate_total
  # which computes total from zero-quantity items, resulting in total_cents = 0
  def update
    @order = Order.unscoped.find(params[:id])
    if @order.update(order_params)
      render json: order_json(@order)
    else
      render json: { errors: @order.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /orders/:id/cancel
  # Scenario 2: cancelling zeroes item quantities via after_save callback
  def cancel
    @order = Order.find(params[:id])
    @order.status = :cancelled
    if @order.save
      render json: { message: "Order ##{@order.id} cancelled", order: order_json(@order) }
    else
      render json: { errors: @order.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # GET /orders/user_orders?user_id=3&status=cancelled
  # Scenario 4: default_scope creates contradictory SQL
  # WHERE status != 3 AND status = 3 -> always empty
  def user_orders
    orders = Order.where(user_id: params[:user_id])
    orders = orders.where(status: params[:status]) if params[:status].present?
    render json: {
      user_id: params[:user_id],
      status_filter: params[:status],
      count: orders.count,
      orders: orders.map { |o| order_json(o) }
    }
  end

  # GET /orders/report
  # Scenario 3: report drops orders with deleted users silently
  def report
    render json: OrderReportService.generate
  end

  private

  def order_params
    params.permit(:user_id, :status, :discount_code, :discount_percent)
  end

  def order_json(order)
    {
      id: order.id,
      user_id: order.user_id,
      user_name: order.user&.name,
      status: order.status,
      total_cents: order.total_cents,
      discount_code: order.discount_code,
      discount_percent: order.discount_percent,
      completed_at: order.completed_at,
      items_count: order.order_items.size
    }
  end

  def item_json(item)
    {
      id: item.id,
      product_name: item.product_name,
      quantity: item.quantity,
      unit_price: item.unit_price,
      tax_rate: item.tax_rate
    }
  end
end

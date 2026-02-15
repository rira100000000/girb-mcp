# frozen_string_literal: true

# シナリオ: 割引計算にバグがある
# 期待: 合計金額が1000円以上なら10%割引
# 実際: 割引が正しく適用されない

class Cart
  attr_reader :items

  def initialize
    @items = []
  end

  def add(name, price, quantity = 1)
    @items << { name: name, price: price, quantity: quantity }
  end

  def subtotal
    @items.sum { |item| item[:price] * item[:quantity] }
  end

  def discount_rate
    subtotal > 1000 ? 0.1 : 0
  end

  def total
    sub = subtotal
    discount = sub * discount_rate
    sub + discount  # BUG: should be sub - discount
  end
end

cart = Cart.new
cart.add("りんご", 200, 3)
cart.add("バナナ", 150, 2)
cart.add("みかん", 100, 4)

debugger

puts "小計: #{cart.subtotal}円"
puts "割引率: #{cart.discount_rate * 100}%"
puts "合計: #{cart.total}円"
puts "期待される合計: #{cart.subtotal * (1 - cart.discount_rate)}円"

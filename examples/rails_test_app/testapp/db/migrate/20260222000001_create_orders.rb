class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :user
      t.integer :status, default: 0, null: false
      t.integer :total_cents, default: 0, null: false
      t.string :discount_code
      t.decimal :discount_percent, precision: 5, scale: 2
      t.datetime :completed_at

      t.timestamps
    end
  end
end

class CreatePosts < ActiveRecord::Migration[8.1]
  def change
    create_table :posts do |t|
      t.string :title
      t.text :body
      t.integer :status
      t.references :user, null: false, foreign_key: true
      t.datetime :published_at

      t.timestamps
    end
  end
end

puts "シードデータを作成中..."

# ユーザー
alice = User.create!(name: "Alice", email: "alice@example.com", role: :admin, active: true)
bob   = User.create!(name: "Bob",   email: "bob@example.com",   role: :editor, active: true)
carol = User.create!(name: "Carol", email: "carol@example.com", role: :member, active: true)
dave  = User.create!(name: "Dave",  email: "dave@example.com",  role: :guest, active: false)

# 投稿
post1 = Post.create!(
  title: "Rails デバッグ入門",
  body: "debug gemを使ったRailsアプリケーションのデバッグ方法について解説します。breakpointの設定、変数の確認、ステップ実行など基本的なデバッグ技法を紹介します。",
  status: :published,
  user: alice,
  published_at: 2.days.ago
)

post2 = Post.create!(
  title: "ActiveRecordのN+1問題を解決する",
  body: "includesやpreloadを使ってN+1クエリを解消する方法を紹介します。BulletやProsopiteなどの検出ツールも併せて解説します。",
  status: :published,
  user: bob,
  published_at: 1.day.ago
)

post3 = Post.create!(
  title: "下書き: テスト駆動開発のすすめ",
  body: "RSpecを使ったTDDの実践方法について。まだ書きかけです。",
  status: :draft,
  user: alice
)

post4 = Post.create!(
  title: "アーカイブ済み: 古い記事",
  body: "この記事はアーカイブされました。",
  status: :archived,
  user: carol
)

# コメント
Comment.create!(body: "とても分かりやすい記事です！", user: bob, post: post1)
Comment.create!(body: "binding.breakの使い方も知りたいです。", user: carol, post: post1)
Comment.create!(body: "N+1問題に困っていたので助かりました。", user: alice, post: post2)
Comment.create!(body: "Bulletの設定方法をもう少し詳しく書いてほしいです。", user: dave, post: post2)

# Ghost User（Scenario 3: レポートで孤立オーダーを作るため）
ghost_user = User.create!(name: "Ghost", email: "ghost@example.com", role: :member, active: true)

# ===== Orders =====

# Order 1: Alice, completed, 割引10%（Scenario 1: 浮動小数点バグトリガー）
order1 = Order.create!(user: alice, status: :completed, discount_code: "SAVE10", discount_percent: 10, completed_at: 3.days.ago)
OrderItem.create!(order: order1, product_name: "Ruby入門書", quantity: 1, unit_price: 33.33, tax_rate: 0.08)
OrderItem.create!(order: order1, product_name: "デバッグツール Pro", quantity: 2, unit_price: 14.99, tax_rate: 0.08)
order1.save! # recalculate_total を発動

# Order 2: Bob, completed（Scenario 2: cancel→再save シナリオ用）
order2 = Order.create!(user: bob, status: :completed, completed_at: 2.days.ago)
OrderItem.create!(order: order2, product_name: "Rails Guide", quantity: 1, unit_price: 45.00, tax_rate: 0.10)
OrderItem.create!(order: order2, product_name: "Testing Kit", quantity: 3, unit_price: 12.50, tax_rate: 0.10)
order2.save!

# Order 3: Ghost User, completed（Scenario 3: 孤立オーダー）
order3 = Order.create!(user: ghost_user, status: :completed, completed_at: 1.day.ago)
OrderItem.create!(order: order3, product_name: "Mystery Box", quantity: 1, unit_price: 25.00, tax_rate: 0.05)
order3.save!

# Order 4: Carol, completed（通常データ）
order4 = Order.create!(user: carol, status: :completed, completed_at: 1.day.ago)
OrderItem.create!(order: order4, product_name: "Keyboard", quantity: 1, unit_price: 89.99, tax_rate: 0.08)
order4.save!

# Order 5: Carol, cancelled（Scenario 4: default_scopeで不可視）
order5 = Order.create!(user: carol, status: :cancelled, completed_at: 5.days.ago)
OrderItem.create!(order: order5, product_name: "返品済みアイテム", quantity: 1, unit_price: 15.00, tax_rate: 0.08)

# Order 6: Alice, pending（一般データ）
order6 = Order.create!(user: alice, status: :pending)
OrderItem.create!(order: order6, product_name: "新ウィジェット", quantity: 2, unit_price: 19.99, tax_rate: 0.10)
order6.save!

# Ghost Userを削除して孤立オーダーを作成（Scenario 3のトリガー）
ghost_user.delete

puts "完了: ユーザー#{User.count}人、投稿#{Post.count}件、コメント#{Comment.count}件、注文#{Order.count}件"

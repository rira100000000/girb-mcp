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

puts "完了: ユーザー#{User.count}人、投稿#{Post.count}件、コメント#{Comment.count}件"

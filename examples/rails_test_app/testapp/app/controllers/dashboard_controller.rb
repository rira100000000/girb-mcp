class DashboardController < ApplicationController
  def index
    @stats = {
      users: User.count,
      posts: Post.count,
      comments: Comment.count,
      published_posts: Post.published.count
    }
    @trending = Post.trending(3)
    @revenue = Order.revenue_stats

    render html: <<~HTML.html_safe
      <!DOCTYPE html>
      <html>
      <head><title>Dashboard</title></head>
      <body>
        <h1>Dashboard</h1>
        <ul>
          <li>Users: #{@stats[:users]}</li>
          <li>Posts: #{@stats[:posts]}</li>
          <li>Comments: #{@stats[:comments]}</li>
          <li>Published: #{@stats[:published_posts]}</li>
        </ul>
        <h2>Trending Posts</h2>
        <ol>
          #{@trending.map { |p| "<li>#{p.title} (#{p.comments.size} comments)</li>" }.join}
        </ol>
        <h2>Revenue</h2>
        <ul>
          <li>Total Revenue: #{@revenue[:total_revenue]} cents</li>
          <li>Average Order: #{@revenue[:average_order]} cents</li>
          <li>Order Count: #{@revenue[:order_count]}</li>
        </ul>
      </body>
      </html>
    HTML
  end
end

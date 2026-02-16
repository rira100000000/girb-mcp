class DashboardController < ApplicationController
  def index
    @stats = {
      users: User.count,
      posts: Post.count,
      comments: Comment.count,
      published_posts: Post.published.count
    }

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
      </body>
      </html>
    HTML
  end
end

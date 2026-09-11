source "https://rubygems.org"

git_source(:github) {|repo_name| "https://github.com/#{repo_name}" }

# Specify your gem's dependencies in dress_socks.gemspec
gemspec

# pry 0.12 calls Object#=~, removed in Ruby 3.2, and cannot even be required.
gem 'pry', '~> 0.14'

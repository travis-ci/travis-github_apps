source "https://rubygems.org"

git_source(:github) {|repo_name| "https://github.com/#{repo_name}" }

# Specify your gem's dependencies in travis-github_apps.gemspec
gemspec
gem 'activesupport', ENV['ACTIVE_RECORD'] if ENV['ACTIVE_RECORD']

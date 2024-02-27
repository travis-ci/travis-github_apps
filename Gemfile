# frozen_string_literal: true

source 'https://rubygems.org'

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

# Specify your gem's dependencies in travis-github_apps.gemspec
gemspec
gem 'activesupport', ENV['ACTIVESUPPORT_VERSION'] if ENV['ACTIVESUPPORT_VERSION']

group :development, :test do
  gem 'rubocop'
  gem 'rubocop-performance'
  gem 'rubocop-rspec'
  gem 'simplecov'
  gem 'simplecov-console'
end

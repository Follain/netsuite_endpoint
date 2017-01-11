source 'https://www.rubygems.org'

gem 'sinatra'
gem 'tilt', '~> 1.4.1'
gem 'tilt-jbuilder', require: 'sinatra/jbuilder'

gem 'jbuilder'
gem 'endpoint_base', github: 'spree/endpoint_base'

gem 'netsuite'
gem 'honeybadger'

group :development do
  gem 'rake'
  gem 'pry'
  gem 'shotgun'
end

group :test do
  gem 'vcr'
  gem 'rack-test'
  gem 'webmock'
end

group :test, :development do
  gem 'pry-byebug'
end

group :production do
  gem 'foreman'
  gem 'unicorn'
end

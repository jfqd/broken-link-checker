# encoding: UTF-8
require 'rubygems'
require 'bundler/setup'
require "#{File.dirname(__FILE__)}/app"
require 'sidekiq/web'

set :run, false

#run Sinatra::Application
run Rack::URLMap.new('/' => Sinatra::Application, '/sidekiq' => Sidekiq::Web)

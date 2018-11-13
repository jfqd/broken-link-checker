# encoding: UTF-8
require 'rubygems'
require 'sinatra'
require 'dotenv/load'
require 'anemone'
require 'benchmark'
require 'pony'
require 'sidekiq'

DOMAIN_REGEX = /\Ahttp(s)?:\/\/[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(([0-9]{1,5})?\/.*)?\z/i
EMAIL_REGEX  = /\A[A-Za-z0-9\-\+\_\.]+\@(\.[A-Za-z0-9\-\+\_]+)*(([a-z0-9]([-a-z0-9]*[a-z0-9])?\.){1,4})([a-z]{2,15})\z/i
SKIP_REGEX   = /^[(A-Za-z0-9\\\-\(\)\|]*$/
PLAIN_TEXT   = {'Content-Type' => 'text/plain'}

configure do
  # http://recipes.sinatrarb.com/p/middleware/rack_commonlogger
  file = File.new("#{settings.root}/log/#{settings.environment}.log", 'a+')
  file.sync = true
  use Rack::CommonLogger, file
  
  Sidekiq.configure_server do |config|
    config.redis = { url: "redis://#{ENV['REDIS_SERVER']}:#{ENV['REDIS_PORT']}/#{ENV['REDIS_DATABASE']}" }
  end

  Sidekiq.configure_client do |config|
    config.redis = { url: "redis://#{ENV['REDIS_SERVER']}:#{ENV['REDIS_PORT']}/#{ENV['REDIS_DATABASE']}" }
  end
end

post '/' do
  begin
    # authorized user?
    if params[:token].blank? || params[:token] != ENV['APP_TOKEN']
      halt 403, PLAIN_TEXT, "unauthorized\n"
    end
    # url parameter valid?
    if params[:url].blank? || !params[:url].match(DOMAIN_REGEX)
      halt 422, PLAIN_TEXT, "url missing or unvalid\n"
    end
    
    PageCrawler.perform_async(
      params[:url],
      validate(params[:email],EMAIL_REGEX),
      validate(params[:bcc],  EMAIL_REGEX),
      validate(params[:skip], SKIP_REGEX)
    )
    
    # output result to caller
    halt 200, PLAIN_TEXT, "job was queued\n"
    
  rescue Exception => e
    logger.warn "[broken-link-checker] Rescue: #{e.message}"
    halt 400, PLAIN_TEXT, e.message
  end
end

get '/ping' do
  'pong'
end

class String
  def blank?
    self == nil || self == ''
  end
end

class NilClass
  def blank?
    self == nil
  end
end

def validate(param,regex)
  !param.blank? && param.match(regex) ? param : nil
end

class PageCrawler
  require 'erb'
  require 'tilt'
  include Sidekiq::Worker
  sidekiq_options :retry => 1, :dead => false
  
  def perform(url, email=nil, bcc=nil, skip=nil)
    o = {
      delay:               1,
      verbose:             false,
      skip_query_strings:  false,
      discard_page_bodies: true,
      pages_queue_limit:   15000,
      user_agent:          "BrokenLinkChecker",
      scan_outgoing_external_links: true
    }
    a = []; c = 0;
  
    t = Benchmark.realtime do
      Anemone.crawl(url,o) do |anemone|
        anemone.skip_links_like /#{skip}/ unless skip.nil?
        anemone.on_every_page do |page|
          if !page.code.nil? and page.code == 404 and !page.url.to_s.include?('%23')
            a << {code: page.code, url: page.url, referer: page.referer}
          end
          c += 1
        end
      end
    end
  
    unless email.nil?
      plaintext = Tilt.new('views/plaintext.erb').render(self, array: a, pages_counter: c, url: url, time: t )
      html_body = Tilt.new('views/html_body.erb').render(self, array: a, pages_counter: c, url: url, time: t )
      send_mail(email,ENV['FROM'],bcc,"#{ENV['SUBJECT']} #{url}", plaintext, html_body)
    end
  end
  
  def send_mail(to,from,bcc,subject,body,html_body)
    Pony.mail(
      to:        to,
      from:      from,
      bcc:       bcc,
      subject:   subject,
      body:      body,
      html_body: html_body,
      via: :smtp,
      via_options: {
        address:              ENV['MAILSERVER'],
        port:                 ENV['PORT'],
        enable_starttls_auto: true,
        user_name:            ENV['MAILUSER'],
        password:             ENV['MAILPDW'],
        authentication:       :plain,
        domain:               ENV['DOMAIN']
      }
    )
  end
end

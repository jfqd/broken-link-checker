# encoding: UTF-8
require 'rubygems'
require 'sinatra'
require 'dotenv/load'
require 'anemone'
require 'benchmark'
require 'pony'

DOMAIN_REGEX = /\Ahttp(s)?:\/\/[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(([0-9]{1,5})?\/.*)?\z/i
EMAIL_REGEX  = /\A[A-Za-z0-9\-\+\_\.]+\@(\.[A-Za-z0-9\-\+\_]+)*(([a-z0-9]([-a-z0-9]*[a-z0-9])?\.){1,4})([a-z]{2,15})\z/i
SKIP_REGEX   = /^[(A-Za-z0-9\\\-\(\)\|]*$/
PLAIN_TEXT   = {'Content-Type' => 'text/plain'}

configure do
  # http://recipes.sinatrarb.com/p/middleware/rack_commonlogger
  file = File.new("#{settings.root}/log/#{settings.environment}.log", 'a+')
  file.sync = true
  use Rack::CommonLogger, file
end

class String
  def blank?
    self == nil || self == ''
  end
end

def send_mail(to,from,subject,body,html_body)
  Pony.mail(
    to:        to,
    from:      from,
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

post '/' do
  begin
    # authorized user?
    if params[:token].blank? || params[:token] != ENV['APP_TOKEN']
      halt 403, PLAIN_TEXT, 'unauthorized'
    end
    # parameters valid?
    if params[:url].blank? || !params[:url].match(DOMAIN_REGEX)
      halt 422, PLAIN_TEXT, 'url missing or unvalid'
    end
    
    o = {delay: 1, verbose: false, skip_query_strings: true, discard_page_bodies: true}
    l = params[:skip].blank? || !params[:skip].match(SKIP_REGEX)
    a = []; c = 0;
    
    t = Benchmark.realtime do
      Anemone.crawl(params[:url],o) do |anemone|
        anemone.skip_links_like /#{l}/ unless l.nil?
        anemone.on_every_page do |page|
          if !page.code.nil? and page.code == 404 and !page.url.to_s.include?('%23')
            a << {code: page.code, url: page.url, referer: page.referer}
          end
          c += 1
        end
      end
    end
    
    # json and xml output possible
    html_body = erb :html_body, locals: { array: a, pages_counter: c, url: params[:url], time: t }
    plaintext = erb :plaintext, locals: { array: a, pages_counter: c, url: params[:url], time: t }
    
    # send a mail with the list of 404 pages
    if !params[:email].blank? && params[:email].match(EMAIL_REGEX)
      send_mail(params[:email],ENV['FROM'],"#{ENV['SUBJECT']} #{params[:url]}", plaintext, html_body)
    end
    
    # output result to caller
    halt 200, PLAIN_TEXT, plaintext
    
  rescue Exception => e
    logger.warn "[broken-link-checker] Rescue: #{e.message}"
    halt 400, PLAIN_TEXT, e.message
  end
end

get '/ping' do
  'pong'
end
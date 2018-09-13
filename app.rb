# encoding: UTF-8
require 'rubygems'
require 'sinatra'
require 'dotenv/load'
require 'anemone'
require 'benchmark'
require 'pony'

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

def send_mail(to,from,subject,message)
  Pony.mail(
    :to      => to,
    :from    => from,
    :subject => subject,
    :body    => message,
    :via => :smtp,
    :via_options => {
      :address              => ENV['MAILSERVER'],
      :port                 => ENV['PORT'],
      :enable_starttls_auto => true,
      :user_name            => ENV['MAILUSER'],
      :password             => ENV['MAILPDW'],
      :authentication       => :plain,
      :domain               => ENV['DOMAIN']
    }
  )
end

post '/' do
  begin
    # authorized user?
    if params[:token].blank? || params[:token] != ENV['APP_TOKEN']
      halt 403, {'Content-Type' => 'text/plain'}, 'unauthorized'
    end
    # parameters valid?
    if params[:url].blank?
      halt 422, {'Content-Type' => 'text/plain'}, 'unvalid parameters: url missing'
    end
    
    o = {delay: 1, verbose: false, skip_query_strings: true}
    a = []
    c = 0
    
    t = Benchmark.realtime do
      Anemone.crawl(params[:url],o) do |anemone|
        anemone.on_every_page do |page|
          if !page.code.nil? and page.code == 404 and !page.url.to_s.include?('%23')
            a << {code: page.code, url: page.url, referer: page.referer}
          end
          c += 1
        end
      end
    end
    
    # json and xml output possible
    text = a.collect {|p| "[#{p[:code]}] #{p[:url]} - Referrer: #{p[:referer]}"}.join("\n")
    message =  %[Crawled #{c.to_s} pages on #{params[:url]} for #{a.size} broken-links in #{(t.round(0))}s\n\n#{text}\n]
    
    # send a mail with the list of 404 pages and the benchmark time
    send_mail(params[:email],ENV['FROM'],"#{ENV['SUBJECT']} #{params[:url]}", message) unless params[:email].blank?
    halt 200, {'Content-Type' => 'text/plain'}, message
    
  rescue Exception => e
    logger.warn "[broken-link-checker] Rescue: #{e.message}"
    halt 400, {'Content-Type' => 'text/plain'}, e.message
  end
end

get '/ping' do
  'pong'
end
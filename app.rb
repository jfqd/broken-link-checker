# encoding: UTF-8
require 'rubygems'
require 'sinatra'
require 'dotenv/load'
require 'anemone'
require 'benchmark'
require 'pony'
require 'sidekiq'
require 'nokogiri'
require 'net/http'

URI_REGEX    = /\Ahttp(s)?:\/\/[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(([0-9]{1,5})?\/.*)?\z/i
DOMAIN_REGEX = /\A[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(([0-9]{1,5})?\/.*)?\z/i
EMAIL_REGEX  = /\A[A-Za-z0-9\-\+\_\.]+\@(\.[A-Za-z0-9\-\+\_]+)*(([a-z0-9]([-a-z0-9]*[a-z0-9])?\.){1,4})([a-z]{2,15})\z/i
SKIP_REGEX   = /^[(A-Za-z0-9\\\-\(\)\|]*$/
PLAIN_TEXT   = {'Content-Type' => 'text/plain'}

def get_redis_config
  if ENV['SENTINEL_MASTER'] != nil && ENV['SENTINEL_MASTER'] != ""
    {
      host: ENV['SENTINEL_MASTER'],
      sentinels: [
        { host: ENV['SENTINEL1'], port: ENV['SENTINEL_PORT'], password: ENV['REDIS_PWD'] },
        { host: ENV['SENTINEL2'], port: ENV['SENTINEL_PORT'], password: ENV['REDIS_PWD'] },
        { host: ENV['SENTINEL3'], port: ENV['SENTINEL_PORT'], password: ENV['REDIS_PWD'] }
      ],
      role: :master,
      password: ENV['REDIS_PWD'],
      db: ENV['REDIS_DATABASE'],
      connect_timeout: 0.2,
      read_timeout: 1.0,
      write_timeout: 0.5,
      reconnect_attempts: 10,
      reconnect_delay: 0.5,
      reconnect_delay_max: 2.0,
      ssl: true,
      ssl_params: {
        ca_file: ENV['CA_FILE'],
        ssl_version: "TLSv1_2",
        verify_mode: OpenSSL::SSL::VERIFY_NONE
      }
    }
  else
    { url: "redis://#{ENV['REDIS_SERVER']}:#{ENV['REDIS_PORT']}/#{ENV['REDIS_DATABASE']}" }
  end
end

configure do
  # http://recipes.sinatrarb.com/p/middleware/rack_commonlogger
  file = File.new("#{settings.root}/log/#{settings.environment}.log", 'a+')
  file.sync = true
  use Rack::CommonLogger, file
    
  Sidekiq.configure_server do |config|
    config.redis = get_redis_config
  end

  Sidekiq.configure_client do |config|
    config.redis = get_redis_config
  end
end

post '/' do
  begin
    # authorized user?
    if params[:token].blank? || params[:token] != ENV['APP_TOKEN']
      halt 403, PLAIN_TEXT, "unauthorized\n"
    end
    # url parameter valid?
    if params[:url].blank? || !params[:url].match(URI_REGEX)
      halt 422, PLAIN_TEXT, "url missing or unvalid\n"
    end
    
    PageCrawler.perform_async(
      params[:url],
      validate(params[:email], EMAIL_REGEX),
      validate(params[:bcc], EMAIL_REGEX),
      validate(params[:skip_pages], SKIP_REGEX),
      validate(params[:skip_domain], DOMAIN_REGEX)
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
  
  def perform(url, email=nil, bcc=nil, skip_pages="", skip_domain="")
    o = {
      delay:               1,
      verbose:             false,
      skip_query_strings:  false,
      discard_page_bodies: true,
      pages_queue_limit:   15000,
      user_agent:          "BrokenLinkChecker",
      scan_outgoing_external_links: true,
      scan_images:         true
    }
    a = []; images = []; img = []; c = 0;
  
    t1 = Benchmark.realtime do
      Anemone.crawl(url,o) do |anemone|
        anemone.skip_links_like /#{skip_pages}/ unless skip_pages.blank?
        anemone.on_every_page do |page|
          # collect 404 pages
          if !page.code.nil? and page.code == 404 and !page.url.to_s.include?('%23')
            a << {code: page.code, url: page.url, referer: page.referer}
          end
          # collect image-urls
          if o[:scan_images] == true
            begin
              html = page.doc.to_s
              images << {page: page.url, images: fetch_image_src(html) } if html != nil && html != ""
            rescue
              # do nothing
            end
          end
          c += 1
        end
      end
    end
    
    # collect 404 images
    t2 = Benchmark.realtime do
      images.each do |h|
        h[:images].each do |i|
          u = i.start_with?("http") ? i : "#{url}#{i}"
          # only process images on own site and skip images
          # on unwanted sites like webanalytic pixels
          if u.include?(url) && h[:page].to_s.include?(url) && !u.include?(skip_domain)
            uri = URI.parse u
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = u.start_with?("https")
            r = http.head(uri.request_uri)
            if !r.code.nil? and r.code.to_i == 404
              img << {code: r.code, url: u, referer: h[:page]}
            end
          end
        end
      end if images != nil && images != []
    end
    
    # send email
    unless email.nil?
      plaintext = Tilt.new('views/plaintext.erb').render(self, array: a, pages_counter: c, url: url, images: img, time: {links: t1, images: t2})
      html_body = Tilt.new('views/html_body.erb').render(self, array: a, pages_counter: c, url: url, images: img, time: {links: t1, images: t2})
      send_mail(email,ENV['FROM'],bcc,"#{ENV['SUBJECT']} #{url}", plaintext, html_body)
    end
  end
  
  def fetch_image_src(html)
    html_doc = Nokogiri::HTML(html)
    nodes = html_doc.xpath("//img[@src]")
    nodes.inject([]) do |uris, node|
      uris << node.attr('src').strip
    end.uniq
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

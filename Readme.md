# Broken-Link-Checker Service

Web-App to crawl a site for 404-errors

## Installation

```
git clone https://github.com/jfqd/broken-link-checker.git
cd broken-link-checker
bundle
cp env.sample .env
```

And change the `APP_TOKEN` and the mailserver settings in the `.env` file to your needs.

## Hosting

We use Phusion Passenger, but you can use thin, puma, unicorn or any other rack server as well. For testing just use:

```
rackup -p 9292
```

## Usage

To check `https://example.com` for 404 links and send the result to `info@example.com` just run:

```
curl -i -X POST --data "token=a-secure-token&url=https://example.com/&email=info@example.com" 127.0.0.1:9292/
```

## Todo

* Add a persistance layer (mysql, etc.)
* Add an endpoint to get crawl results
* Add an option to check images

Copyright (c) 2018 Stefan Husch, qutic development.
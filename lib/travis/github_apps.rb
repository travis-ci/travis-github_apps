require "travis/github_apps/version"

require 'active_support'
require 'jwt'
require 'redis'
require 'faraday'

module Travis
  # Object for working with GitHub Apps installations
  #
  class GithubApps
    # Access token is the "Installation Access Token" required to authenticate
    #   this application against the GitHub Apps API.
    #
    # https://developer.github.com/apps/building-github-apps/authentication-options-for-github-apps/#authenticating-as-an-installation
    #

    # GitHub Apps tokens have a maximum life of 10 minutes, but we'll use 9 to
    #   allow a healthy buffer for timing issues, lag, etc.
    #
    APP_TOKEN_TTL = 540 # 9 minutes in seconds

    attr_reader :accept_header, :cache_client, :installation_id

    def initialize(installation_id, config = {})
      # ID of the GitHub App. This value can be found on the "General Information"
      #   page of the App.
      #
      # TODO: this value is set to those of the "travis-ci-staging" app for
      #   development.
      #
      @github_apps_id      = ENV['GITHUB_APPS_ID'] || config[:apps_id] || 10131

      @github_api_endpoint = ENV['GITHUB_API_ENDPOINT'] || config[:api_endpoint] || "https://api.github.com"
      @github_private_pem  = ENV['GITHUB_PRIVATE_PEM'] || config[:private_pem] || read_private_key_from_file
      @github_private_key  = OpenSSL::PKey::RSA.new(@github_private_pem)

      @accept_header       = config.fetch(:accept_header, "application/vnd.github.machine-man-preview+json")
      @cache_client        = Redis.new(config[:redis] || { url: 'redis://localhost' })
      @installation_id     = installation_id
    end

    # Installation ID is served to us in the initial InstallationEvent callback.
    #
    # An array of all installations for a given App is available at:
    #   GET /app/installations
    #
    # The installation_id of the travis-vi-staging app on the Travis-CI org is
    #   120134
    #
    def access_token
      # Fetch from cache. We can expect this to be `nil` if unset or expired.
      #
      access_token = cache_client.get(cache_key_for_access_token)

      return access_token if access_token

      fetch_new_access_token
    end

    # Issue a GET with the supplied URL in the context of our GitHub App
    #
    def get_with_app(url)
      github_api_conn.get do |request|
        request.url url

        request.headers['Authorization'] = "Token #{access_token}"
        request.headers['Accept']        = accept_header
      end
    end

    # Issue a POST with the supplied URL in the context of our GitHub App
    #
    def post_with_app(url, payload = '')
      github_api_conn.post do |request|
        request.url url

        request.headers['Authorization'] = "Token #{access_token}"
        request.headers['Accept']        = accept_header
        request.body = payload
      end
    end

    private

    def fetch_new_access_token
      response = github_api_conn.post do |req|
        req.url "/installations/#{installation_id}/access_tokens"
        req.headers['Authorization'] = "Bearer #{authorization_jwt}"
        req.headers['Accept'] = "application/vnd.github.machine-man-preview+json"
      end

      # We probably want to do something different than `raise` here but I don't
      #   know what yet.
      #
      if response.status != 201
        raise("Failed to obtain token from GitHub: #{response.status} - #{response.body}")
      end

      # Parse the response for the token and expiration
      #
      response_body = JSON.load(response.body)
      github_access_token  = response_body.fetch('token')

      # Store the access_token in redis, with a computed expiration. We need to
      #   recalculate this here instead of using APP_TOKEN_TTL because we don't
      #   know how long the call to #fetch_new_access_token took, and could create
      #   a window of a few second for API errors at the end of a token's life.
      #
      cache_client.set(
        cache_key_for_access_token,
        github_access_token,
        { ex: APP_TOKEN_TTL }
      )

      github_access_token
    end

    def authorization_jwt
      JWT.encode(jwt_payload, @github_private_key, "RS256")
    end

    def jwt_payload(app_token_ttl: APP_TOKEN_TTL)
      time = Time.now.to_i
      @payload = {
        # iat: issued at time
        #
        iat: time,
        # exp: JWT expiration time in seconds (10 minute maximum)
        #
        exp: time + app_token_ttl,

        # iss: GitHub App's identifier
        #
        iss: @github_apps_id
      }
    end

    def github_api_conn
      @_github_api_conn ||= Faraday.new(url: @github_api_endpoint)
    end

    def cache_key_for_access_token
      "github_access_token:#{installation_id}"
    end

    # Attempt to read in the private key from ENV['GITHUB_PRIVATE_PEM'], and then
    #   as a convenience, from a local file. This isn't something we
    #   should be doing in production, as the pem should never be checked into
    #   source control. If you need a copy of this for development, ask Kerri.
    #
    def read_private_key_from_file
      pem_files_in_root = Dir["*.pem"]

      @_github_private_key ||= if pem_files_in_root.any?
        File.read(pem_files_in_root.first)
      else
        raise "Sorry, can't find local pem file"
      end
    end
  end
end

# frozen_string_literal: true

require 'travis/github_apps/version'

require 'active_support'
require 'json'
require 'jwt'
require 'redis'
require 'faraday'
require 'faraday/follow_redirects'

module Travis
  # Object for working with GitHub Apps installations
  #
  class GithubApps
    # Access token is the "Installation Access Token" required to authenticate
    #   this application against the GitHub Apps API.
    #
    # https://developer.github.com/apps/building-github-apps/authenticating-with-github-apps/
    #

    # GitHub allows JWT token to be valid up to 10 minutes.
    # We set this to 9 minutes, to be sure.
    #
    JWT_TOKEN_TTL = 9 * 60

    # GitHub Apps tokens have a maximum life of 60 minutes, but we'll use 40 to
    #   allow a healthy buffer for timing issues, lag, etc.
    #
    APP_TOKEN_TTL = 40 * 60 # 40 minutes in seconds

    attr_reader :accept_header, :cache, :installation_id, :debug, :repositories

    def initialize(installation_id, config = {}, repositories = nil) # rubocop:disable Metrics/CyclomaticComplexity
      # ID of the GitHub App. This value can be found on the "General Information"
      #   page of the App.
      #
      # TODO: this value is set to those of the "travis-ci-staging" app for
      #   development.
      #
      @github_apps_id             = ENV['GITHUB_APPS_ID'] || config[:apps_id] || 10_131

      @github_api_endpoint        = ENV['GITHUB_API_ENDPOINT'] || config[:api_endpoint] || "https://api.github.com"
      @github_private_pem         = ENV['GITHUB_PRIVATE_PEM'] || config[:private_pem] || read_private_key_from_file
      @github_private_key         = OpenSSL::PKey::RSA.new(@github_private_pem)

      @accept_header              = config.fetch(:accept_header, 'application/vnd.github.machine-man-preview+json')
      @installation_id            = installation_id
      @repositories               = repositories
      @cache                      = Redis.new(config[:redis]) if config[:redis]
      @debug                      = !!config[:debug]
      @content_permission         = ENV['GITHUB_APPS_CONTENT_PERMISSION'] || config[:content_permission] || 'read'
      @security_events_permission = ENV['GITHUB_APPS_SECURITY_EVENTS_PERMISSION'] || config[:security_events_permission] || nil
      @workflows_permission       = ENV['GITHUB_APPS_WORKFLOWS_PERMISSION'] || config[:workflows_permission] || nil
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
      access_token = read_cache

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

    # Issue a PATCH with the supplied URL in the context of our GitHub App
    #
    def patch_with_app(url, payload = '')
      github_api_conn.patch do |request|
        request.url url

        request.headers['Authorization'] = "Token #{access_token}"
        request.headers['Accept']        = accept_header
        request.body = payload
      end
    end

    private

    def fetch_token(use_custom_permissions)
      github_api_conn.post do |req|
        req.url "app/installations/#{installation_id}/access_tokens"
        req.headers['Authorization'] = "Bearer #{authorization_jwt}"
        req.headers['Accept'] = "application/vnd.github.machine-man-preview+json"
        req.body = JSON.dump({
          :repository_ids => repositories_list,
          :permissions => use_custom_permissions ? permissions : default_permissions
        }) if repositories
      end
    end

    def has_custom_permissions
      @has_custom_permissions ||= @content_permission != 'read' || @security_events_permission || @workflows_permission
    end


    def fetch_new_access_token
      response = fetch_token(true)
      # We probably want to do something different than `raise` here but I don't
      #   know what yet.
      #
      if response.status == 422 && has_custom_permissions
          response = fetch_token(false)
      end

      if response.status != 201
        raise("Failed to obtain token from GitHub: #{response.status} - #{response.body}")
      end

      # Parse the response for the token and expiration
      #
      response_body = JSON.parse(response.body)
      github_access_token = response_body.fetch('token')

      # Store the access_token in redis, with a computed expiration. We need to
      #   recalculate this here instead of using APP_TOKEN_TTL because we don't
      #   know how long the call to #fetch_new_access_token took, and could create
      #   a window of a few second for API errors at the end of a token's life.
      #
      write_cache(github_access_token)

      github_access_token
    end

    def permissions
      perm = { :contents => @content_permission}
      perm[:security_events] = @security_events_permission if @security_events_permission
      perm[:workflows] = @workflows_permission if @workflows_permission
      perm
    end

    def default_permissions
      { :contents => 'read' }
    end

    def repositories_list
      @repositories_list ||= repositories.compact.map(&:to_s).reject(&:empty?)
    end

    def authorization_jwt
      JWT.encode(jwt_payload, @github_private_key, 'RS256')
    end

    def jwt_payload(jwt_token_ttl: JWT_TOKEN_TTL)
      time = Time.now.to_i
      @payload = {
        # iat: issued at time
        #
        iat: time,
        # exp: JWT expiration time in seconds (10 minute maximum)
        #
        exp: time + jwt_token_ttl,

        # iss: GitHub App's identifier
        #
        iss: @github_apps_id.to_i
      }
    end

    def github_api_conn
      @_github_api_conn ||= Faraday.new(url: @github_api_endpoint) do |f|
        f.response :logger if debug
        f.response :follow_redirects, limit: 5
        f.request :retry
        f.adapter Faraday.default_adapter
      end
    end

    def read_cache
      cache&.get(cache_key)
    end

    def write_cache(token)
      cache&.set(cache_key, token, ex: APP_TOKEN_TTL)
    end

    def cache_key
      return "github_access_token_repo:#{installation_id}_#{repositories_list.join('-')}" if repositories

      "github_access_token:#{installation_id}"
    end

    # Attempt to read in the private key from ENV['GITHUB_PRIVATE_PEM'], and then
    #   as a convenience, from a local file. This isn't something we
    #   should be doing in production, as the pem should never be checked into
    #   source control. If you need a copy of this for development, ask Kerri.
    #
    def read_private_key_from_file
      pem_files_in_root = Dir['*.pem']

      @_github_private_key ||= if pem_files_in_root.any?
                                 File.read(pem_files_in_root.first)
                               else
                                 raise "Sorry, can't find local pem file"
                               end
    end
  end
end

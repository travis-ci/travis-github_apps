module Travis
  class Error < StandardError
    attr_reader :message

    def initialize(msg)
      @message = msg
    end
  end

  class TokenUnavailableError < Error; end
end

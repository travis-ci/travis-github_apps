RSpec.describe Travis::GithubApps do
  it "has a version number" do
    expect(Travis::GithubApps::VERSION).not_to be nil
  end

  let(:subject){ Travis::GithubApps.new }

  let(:payload){ {
    # Note that Time.now is frozen in tests, so we can get away with multiple
    #   calls to it without drift.
    #
    iat: Time.now.to_i,
    exp: Time.now.to_i + subject.class::APP_TOKEN_TTL,
    iss: subject.instance_variable_get(:@github_apps_id)
  }}

  let(:installation_id){ 12345 }

  before { ENV['GITHUB_PRIVATE_PEM'] = File.read('spec/fixtures/github_pem.txt') }
  after  { ENV.delete('GITHUB_PRIVATE_PEM') }

  describe "#initialize" do
    it "intializes and loads initial configuration values" do
      expect(subject).to be

      # ivars
      #
      expect(subject.instance_variable_get(:@github_apps_id)).to eq 10131

      expect(subject.instance_variable_get(:@github_private_pem))
        .to include("BEGIN RSA PRIVATE KEY")

      expect(subject.instance_variable_get(:@github_private_key))
        .to be_a OpenSSL::PKey::RSA
    end

    context "when accept-header is specified" do
      let(:subject) { Travis::GithubApps.new({accept_header: "application/vnd.github.antiope-preview+json"})}

      it "intializes" do
        expect(subject).to be
      end
    end
  end

  describe "#authorization_jwt" do
    it "returns a JWT string" do
      expect(subject.send(:authorization_jwt)).to be_a String
    end
  end

  describe "#jwt_payload" do
    it "formats a JWT payload correctly" do
      expect(subject.send(:jwt_payload)).to eq payload
    end
  end

  describe "#access_token" do
    context "when the access token exists in the cache" do
      it "returns the value contained in the cache" do
        random_string = ('a'..'z').to_a.shuffle[0,8].join

        Redis.any_instance.stubs(:get).returns(random_string)

        expect(subject.access_token(installation_id)).to eq random_string
      end
    end

    context "when the access token does not exist in the cache" do
      # This test is treading perilously close to testing that stubbing works
      #
      it "returns the value from an API lookup" do
        random_string = ('a'..'z').to_a.shuffle[0,8].join

        Redis.any_instance.stubs(:get).returns(nil)

        subject.expects(:fetch_new_access_token).with(installation_id).once.returns(random_string)

        expect(subject.access_token(installation_id)).to eq random_string
      end
    end
  end

  class FakeGitHubResponse
    def status
      201
    end

    def body
      "{\"token\":\"#{access_token}\",\"expires_at\":\"2018-04-03T20:52:14Z\"}"
    end

    def access_token
      "github_apps_access_token"
    end
  end

  describe "#fetch_new_access_token" do
    let(:fake_github_response){ FakeGitHubResponse.new }

    context "on a 201 response" do
      it "sets the access token in the cache and returns it to the caller" do
        subject.expects(:post_with_app).once.returns(fake_github_response)
        Redis.any_instance.stubs(:set).returns(nil)

        expect(subject.send(:fetch_new_access_token, installation_id)).to eq fake_github_response.access_token
      end
    end

    context "on a non-201 response" do
      it "raises an error" do
        fake_github_response.expects(:status).at_least_once.returns(404)
        subject.expects(:post_with_app).once.returns(fake_github_response)

        expect {
          subject.send(:fetch_new_access_token, installation_id)
        }.to raise_error(RuntimeError)
      end
    end
  end
end

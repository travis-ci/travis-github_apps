RSpec.describe Travis::GithubApps do
  it "has a version number" do
    expect(Travis::GithubApps::VERSION).not_to be nil
  end

  let(:config) { { redis: { url: 'redis://localhost' } } }
  let(:subject){ Travis::GithubApps.new(installation_id, config) }
  let(:installation_id) { '12345' }

  let(:payload){ {
    # Note that Time.now is frozen in tests, so we can get away with multiple
    #   calls to it without drift.
    #
    iat: Time.now.to_i,
    exp: Time.now.to_i + subject.class::JWT_TOKEN_TTL,
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

        expect(subject.access_token).to eq random_string
      end
    end

    context "when the access token does not exist in the cache" do
      # This test is treading perilously close to testing that stubbing works
      #
      it "returns the value from an API lookup" do
        random_string = ('a'..'z').to_a.shuffle[0,8].join

        Redis.any_instance.stubs(:get).returns(nil)

        subject.expects(:fetch_new_access_token).once.returns(random_string)

        expect(subject.access_token).to eq random_string
      end
    end
  end

  describe "#fetch_new_access_token" do
    let(:conn) {
      Faraday.new do |builder|
        builder.adapter :test do |stub|
          stub.post("/apps/installations/12345/access_tokens") { |env| [201, {}, "{\"token\":\"github_apps_access_token\",\"expires_at\":\"2018-04-03T20:52:14Z\"}"] }
          stub.post("/apps/installations/23456/access_tokens") { |env| [404, {}, ""] }
        end
      end
    }

    context "on a 201 response" do
      it "sets the access token in the cache and returns it to the caller" do
        subject.expects(:github_api_conn).returns(conn)
        Redis.any_instance.stubs(:set).returns(nil)

        expect(subject.send(:fetch_new_access_token)).to eq "github_apps_access_token"
      end
    end

    context "on a non-201 response" do
      let(:installation_id) { '23456' }
      it "raises an error" do
        subject.expects(:github_api_conn).returns(conn)
        Redis.any_instance.stubs(:set).returns(nil)

        expect {
          subject.send(:fetch_new_access_token)
        }.to raise_error(RuntimeError)
      end
    end
  end
end

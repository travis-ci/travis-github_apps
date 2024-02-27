# frozen_string_literal: true

RSpec.describe Travis::GithubApps do
  after  { ENV.delete('GITHUB_PRIVATE_PEM') }
  before { ENV['GITHUB_PRIVATE_PEM'] = File.read('spec/fixtures/github_pem.txt') }

  let(:installation_id) { 12_345 }
  let(:payload) do
    {
      # Note that Time.now is frozen in tests, so we can get away with multiple
      #   calls to it without drift.
      #
      iat: Time.now.to_i,
      exp: Time.now.to_i + subject.class::JWT_TOKEN_TTL,
      iss: subject.instance_variable_get(:@github_apps_id)
    }
  end
  let(:subject) { described_class.new(installation_id, config) }
  let(:config) { { redis: { url: 'redis://localhost' } } }

  it 'has a version number' do
    expect(Travis::GithubApps::VERSION).not_to be nil
  end

  describe '#initialize' do
    it 'intializes and loads initial configuration values' do
      expect(subject).to be_a(described_class)

      # ivars
      #
      expect(subject.instance_variable_get(:@github_apps_id)).to eq 10_131

      expect(subject.instance_variable_get(:@github_private_pem))
        .to include('BEGIN RSA PRIVATE KEY')

      expect(subject.instance_variable_get(:@github_private_key))
        .to be_a OpenSSL::PKey::RSA
    end

    context 'when accept-header is specified' do
      let(:subject) { described_class.new({ accept_header: 'application/vnd.github.antiope-preview+json' }) }

      it 'intializes' do
        expect(subject).to be_a(described_class)
      end
    end
  end

  describe '#authorization_jwt' do
    it 'returns a JWT string' do
      expect(subject.send(:authorization_jwt)).to be_a String
    end
  end

  describe '#jwt_payload' do
    it 'formats a JWT payload correctly' do
      expect(subject.send(:jwt_payload)).to eq payload
    end
  end

  describe '#access_token' do
    context 'when the access token exists in the cache' do
      it 'returns the value contained in the cache' do
        random_string = ('a'..'z').to_a.sample(8).join

        Redis.any_instance.stubs(:get).returns(random_string)

        expect(subject.access_token).to eq random_string
      end
    end

    context 'when the access token does not exist in the cache' do
      # This test is treading perilously close to testing that stubbing works
      #
      it 'returns the value from an API lookup' do
        random_string = ('a'..'z').to_a.sample(8).join

        Redis.any_instance.stubs(:get).returns(nil)

        subject.expects(:fetch_new_access_token).once.returns(random_string)

        expect(subject.access_token).to eq random_string
      end
    end
  end

  describe '#fetch_new_access_token' do
    let(:conn) do
      Faraday.new do |builder|
        builder.adapter :test do |stub|
          stub.post('/app/installations/12345/access_tokens') { |_env| [201, {}, '{"token":"github_apps_access_token","expires_at":"2018-04-03T20:52:14Z"}'] }
          stub.post('/app/installations/23456/access_tokens') { |_env| [404, {}, ''] }
          stub.post('/app/installations/45678/access_tokens', JSON.dump({ repository_ids: %w[123 456], permissions: { contents: 'read' } })) { |_env| [201, {}, '{"token":"github_apps_access_token","expires_at":"2018-04-03T20:52:14Z","repositories":"[{id:123},{id:456}]"}'] }
          stub.post('/app/installations/56789/access_tokens', JSON.dump({ repository_ids: ['789'], permissions: { contents: 'read' } })) { |_env| [404, {}, ''] }
        end
      end
    end

    context 'on a 201 response' do
      it 'sets the access token in the cache and returns it to the caller' do
        subject.expects(:github_api_conn).returns(conn)
        Redis.any_instance.stubs(:set).returns(nil)

        expect(subject.send(:fetch_new_access_token)).to eq 'github_apps_access_token'
      end
    end

    context 'with repository_ids on a 201 response' do
      let(:installation_id) { '45678' }
      let(:repositories) { [123, 456] }
      let(:subject) { described_class.new(installation_id, config, repositories) }

      it 'sets the access token in the cache and returns it to the caller' do
        subject.expects(:github_api_conn).returns(conn)
        Redis.any_instance.stubs(:set).returns(nil)

        expect(subject.send(:fetch_new_access_token)).to eq 'github_apps_access_token'
      end
    end

    context 'on a non-201 response' do
      let(:installation_id) { '23456' }

      it 'raises an error' do
        subject.expects(:github_api_conn).returns(conn)
        Redis.any_instance.stubs(:set).returns(nil)

        expect do
          subject.send(:fetch_new_access_token)
        end.to raise_error(RuntimeError)
      end
    end

    context 'with repository_ids on a non-201 response' do
      let(:installation_id) { '56789' }
      let(:repositories) { [789] }
      let(:subject) { described_class.new(installation_id, config, repositories) }

      it 'raises an error' do
        subject.expects(:github_api_conn).returns(conn)
        Redis.any_instance.stubs(:set).returns(nil)

        expect do
          subject.send(:fetch_new_access_token)
        end.to raise_error(RuntimeError)
      end
    end
  end
end

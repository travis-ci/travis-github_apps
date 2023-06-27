
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "travis/github_apps/version"

Gem::Specification.new do |spec|
  spec.name          = "travis-github_apps"
  spec.version       = Travis::GithubApps::VERSION
  spec.authors       = ["Kerri Miller"]
  spec.email         = ["kerrizor@kerrizor.com"]

  spec.summary       = %q{A small library for fetching, storing, and renewing GitHub Apps access tokens}
  spec.description   = %q{A small library for fetching, storing, and renewing GitHub Apps access tokens}
  spec.homepage      = "https://github.com/travis-ci/github_apps"
  spec.license       = "MIT"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"
  else
    raise "RubyGems 2.0 or newer is required to protect against " \
      "public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "mocha"
  spec.add_development_dependency "rake", "~> 13"
  spec.add_development_dependency "rspec", "~> 3"

  spec.add_dependency "activesupport", ">= 3.2"
  spec.add_dependency "jwt"
  spec.add_dependency "redis"
  spec.add_dependency "faraday", "~> 2"
end

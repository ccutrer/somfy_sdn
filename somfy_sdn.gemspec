# frozen_string_literal: true

require_relative "lib/sdn/version"

Gem::Specification.new do |s|
  s.name = "somfy_sdn"
  s.version = SDN::VERSION
  s.platform = Gem::Platform::RUBY
  s.authors = ["Cody Cutrer"]
  s.email = "cody@cutrer.com'"
  s.homepage = "https://github.com/ccutrer/somfy_sdn"
  s.summary = "Library for communication with Somfy SDN RS-485 motorized shades"
  s.license = "MIT"
  s.metadata["rubygems_mfa_required"] = "true"

  s.bindir = "exe"
  s.executables = ["somfy_sdn"]
  s.files = Dir["{exe,lib}/**/*"]

  s.required_ruby_version = ">= 2.5"

  s.add_dependency "ccutrer-serialport", "~> 1.0"
  s.add_dependency "curses", "~> 1.4"
  s.add_dependency "mqtt-homeassistant", "~> 1.0"
  s.add_dependency "net-telnet-rfc2217", "~> 1.0"
  s.add_dependency "thor", "~> 1.1"

  s.add_development_dependency "rake", "~> 13.0"
end

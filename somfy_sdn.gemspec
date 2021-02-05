require_relative "lib/sdn/version"

Gem::Specification.new do |s|
  s.name = 'somfy_sdn'
  s.version = SDN::VERSION
  s.platform = Gem::Platform::RUBY
  s.authors = ["Cody Cutrer"]
  s.email = "cody@cutrer.com'"
  s.homepage = "https://github.com/ccutrer/somfy_sdn"
  s.summary = "Library for communication with Somfy SDN RS-485 motorized shades"
  s.license = "MIT"

  s.executables = ['sdn_mqtt_bridge']
  s.files = Dir["{bin,lib}/**/*"]

  s.add_dependency 'curses', "~> 1.4"
  s.add_dependency 'mqtt', "~> 0.5.0"
  s.add_dependency 'net-telnet-rfc2217', "~> 0.0.3"
  s.add_dependency 'ccutrer-serialport', "~> 1.0.0"

  s.add_development_dependency 'byebug', "~> 9.0"
  s.add_development_dependency 'rake', "~> 13.0"
end

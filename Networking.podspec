Pod::Spec.new do |s|
  s.name = 'Networking'
  s.version = '0.1'
  s.license = { :type => "MIT", :file => "LICENSE" }
  s.summary = 'HTTP Client for seamless authentication handling and pausing/resuming of requests'
  s.homepage = 'https://github.com/jensgrud/Networking'
  s.authors = { 'Jens Grud' => 'jens@heapsapp.com' }
  s.source = { :git => 'https://github.com/jensgrud/Networking.git', :tag => s.version }

  s.ios.deployment_target = '8.0'
  s.osx.deployment_target = '10.10'
  s.watchos.deployment_target = '2.0'
  s.tvos.deployment_target = '9.0'

  s.source_files = '*.swift'
  s.requires_arc = true

  s.dependency 'Alamofire', '~> 3.2'
end
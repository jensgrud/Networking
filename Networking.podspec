Pod::Spec.new do |s|
  s.name = 'Networking'
  s.version = '1.1.7'
  s.license = { :type => "MIT", :file => "LICENSE" }
  s.summary = 'Alamofire Swift 3.0 wrapper for seamless authentication handling and pausing/resuming of requests'
  s.homepage = 'https://github.com/jensgrud/Networking'
  s.authors = { 'Jens Grud' => 'jens@heapsapp.com' }
  s.source = { :git => 'https://github.com/jensgrud/Networking.git', :tag => s.version }

  s.ios.deployment_target = '8.0'

  s.source_files = 'Networking.swift'
  s.requires_arc = true

  s.dependency 'Alamofire'
end

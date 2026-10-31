Pod::Spec.new do |s|
  s.name             = 'yunx_media'
  s.version          = '1.0.0'
  s.summary          = 'AVFoundation DASH muxer for YunX'
  s.homepage         = 'https://github.com/cc1477/YunX-iOS'
  s.license          = { :type => 'AGPL-3.0' }
  s.author           = { 'YunX' => 'yunx@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'AVFoundation'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end

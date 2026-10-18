#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint mic_recorder.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'mic_recorder'
  s.version          = '0.1.0'
  s.summary          = 'Production-grade microphone recording for Flutter: raw PCM streaming, WAV and native encoded file output, audio session handling, interruption recovery and input device switching.'
  s.description      = <<-DESC
Production-grade microphone recording for Flutter: raw PCM streaming, WAV and native encoded file output (AAC, Apple Lossless, Opus, FLAC, AMR), live dBFS metering, permission management, audio session handling, interruption recovery and input device switching.
                       DESC
  s.homepage         = 'https://bilalahmed24.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Bilal Ahmed' => 'bilaluddinahmed24@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'mic_recorder/Sources/mic_recorder/**/*'
  s.dependency 'Flutter'

  s.platform = :ios, '15.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'mic_recorder_privacy' => ['mic_recorder/Sources/mic_recorder/PrivacyInfo.xcprivacy']}

  s.ios.deployment_target = '15.0'
end

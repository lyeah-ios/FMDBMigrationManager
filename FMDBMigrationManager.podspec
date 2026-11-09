#
# Be sure to run `pod lib lint FMDBMigrationManager.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'FMDBMigrationManager'
  s.version          = '3.0.0'
  s.summary          = 'Versioned SQLite database migrations using FMDB.'
  s.description      = 'Discovers and applies SQL or Objective-C migrations to an FMDB database.'

  s.homepage         = 'https://github.com/lyeah-ios/FMDBMigrationManager'
  s.license          = { :type => 'MIT and Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Blake Watters' => 'blakewatters@gmail.com', 'zisu' => 'zisulwl@163.com' }
  s.source           = { :git => 'https://github.com/lyeah-ios/FMDBMigrationManager.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.requires_arc = true
  s.source_files = 'FMDBMigrationManager/Core/**/*.{h,m}'
  s.public_header_files = 'FMDBMigrationManager/Core/**/*.h'
  s.preserve_paths = 'LICENSE-APACHE'
  s.default_subspec = 'System'

  s.subspec 'System' do |system|
    system.dependency 'FMDB/standard', '>= 2.7.12'
  end

  s.subspec 'Standalone' do |standalone|
    standalone.dependency 'FMDB/standalone', '>= 2.7.12'
  end
end

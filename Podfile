platform :ios, '14.0'

use_frameworks!
use_modular_headers!

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'YES'
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
      config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
      if target.name == 'Proximiio' || target.name == 'ProximiioProcessor'
        config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf'
        config.build_settings['STRIP_INSTALLED_PRODUCT'] = 'NO'
      else
        config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
      end
    end
  end

  # This is necessary for Xcode 14, because it signs resource bundles by default
    # when building for devices.
    installer.target_installation_results.pod_target_installation_results
      .each do |pod_name, target_installation_result|
      target_installation_result.resource_bundle_targets.each do |resource_bundle_target|
        resource_bundle_target.build_configurations.each do |config|
          config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
        end
      end
    end
end

target 'ProximiioWebViewDemo' do
  pod 'Proximiio', '5.3.0'
  pod 'ProximiioProcessor'
  pod 'CrystDBCipher'
end

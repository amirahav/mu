default['apache']['mod_ssl']['cipher_suite'] = "ALL:!ADH:!EXPORT:!SSLv2:RC4+RSA:+HIGH:+MEDIUM:+LOW"
default['apache']['mod_ssl']['directives']['SSLProtocol'] = "all -SSLv2 -SSLv3"
default['apache']['traceenable'] = "Off"
default['s3_bucket'] = "egt-labs"
default['s3_bucket_path'] = "cap-public"
default['s3_public_url'] = "https://s3.amazonaws.com/cap-public/cap-demo"
default['winapps']['jackrabbit'] = "jackrabbit-webapp-2.8.0.war"
default['winapps']['sample'] = "sample.war"
default['winapps']['razuna'] = "razuna.war"
default['linux_apps'] = ["drupal"]
default['application_attributes']['tiered_apps']['domain_name'] = "example.com"

if platform_family?("windows")
  default['java']['max_heap_size'] = '2G'
  default['java']['java_home'] = "C:\\bin\\java"
  default['java']['windows']['package_name'] = 'Java SE Development Kit 7 Update 80 (64-bit)'
  default['java']['windows']['url'] = "https://s3.amazonaws.com/cap-public/jdk-7u80-windows-x64.exe"
  # default['java']['windows']['package_name'] = 'Java SE Development Kit 8 Update 45 (64-bit)'
  # default['java']['windows']['url'] = "https://s3.amazonaws.com/cap-public/jdk-8u45-windows-x64.exe"
  # default['java']['windows']['checksum'] = "979ec7d6c93c6f36b32b8d532d736015"
else
  default['java']['max_heap_size'] = "#{(node['memory']['total'].to_i * 0.6).floor / 1024}m"
  default['java']['oracle']['accept_oracle_download_terms'] = true
  default['java']['java_home'] = '/usr/lib/jvm/java'
  default['java']['install_flavor'] = 'oracle'
  default['java']['jdk_version'] = 8
  default['java']['jdk']['8']['x86_64']['url'] = "http://download.oracle.com/otn-pub/java/jdk/8u45-b14/jdk-8u45-linux-x64.tar.gz"
  default['java']['jdk']['8']['x86_64']['checksum'] = "1ad9a5be748fb75b31cd3bd3aa339cac"
end

default['tomcat']['generate_ssl_cert'] = false
default['tomcat']['base_version'] = 7
default['tomcat']['base_instance'] = "tomcat#{node['tomcat']['base_version']}" if node['platform_version'].to_i == 6 and platform_family?('rhel')

if node['java']['jdk_version'] == 8
  default['tomcat']['java_options'] = "-Djava.awt.headless=true -Xms256m -Xmx#{node['java']['max_heap_size']} -Xrs -XX:PerfDataSamplingInterval=500 -XX:+UseParallelOldGC -XX:+UseParallelGC -XX:SoftRefLRUPolicyMSPerMB=36000"
else
  default['tomcat']['java_options'] = "-Djava.awt.headless=true -Xms256m -Xmx#{node['java']['max_heap_size']} -Xrs -XX:PerfDataSamplingInterval=500 -XX:+UseParallelOldGC -XX:+UseParallelGC -XX:MaxPermSize=256m -XX:SoftRefLRUPolicyMSPerMB=36000"
end

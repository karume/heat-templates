node default {

# for AIO deployments + MidoNet

$openstack_release = 'kilo'
$keystone_admin_password = 'supersecret'
$rabbitmq_password = 'megasecret'
$keystone_db_password = 'secret'
$keystone_db_host = 'localhost'
$keystone_admin_token = $keystone_admin_password
$glance_db_password = 'secret'
$glance_db_host = 'localhost'
$neutron_db_password = 'secret'
$neutron_db_host = 'localhost'
$nova_db_password = 'secret'
$nova_db_host = 'localhost'

# class { 'openstack::db::mysql':
#    mysql_root_password  => 'changeme',
#    keystone_db_password => 'changeme',
#    glance_db_password   => 'changeme',
#    nova_db_password     => 'changeme',
#    cinder_db_password   => 'changeme',
#    neutron_db_password  => 'changeme',
#    allowed_hosts        => ['127.0.0.1', '10.0.0.%'],
#  }

case $::osfamily {
  'Debian': {
    include ::apt
    class { '::openstack_extras::repo::debian::ubuntu':
      release         => "${openstack_release}",
      repo            => 'proposed',
      package_require => true,
    }
    $package_provider = 'apt'
  }
  'RedHat': {
    class { '::openstack_extras::repo::redhat::redhat':
      manage_rdo => false,
      repo_hash  => {
        'openstack-common-testing'  => {
          'baseurl'  => 'http://cbs.centos.org/repos/cloud7-openstack-common-testing/x86_64/os/',
          'descr'    => 'openstack-common-testing',
          'gpgcheck' => 'no',
        },
        "openstack-${openstack_release}-testing" => {
          'baseurl'  => "http://cbs.centos.org/repos/cloud7-openstack-${openstack_release}-testing/x86_64/os/",
          'descr'    => "openstack-${openstack_release}-testing",
          'gpgcheck' => 'no',
        },
        "openstack-${openstack_release}-trunk"   => {
          'baseurl'  => "http://trunk.rdoproject.org/centos7-${openstack_release}/current/",
          'descr'    => "openstack-${openstack_release}-trunk",
          'gpgcheck' => 'no',
        },
      },
    }
    package { 'openstack-selinux': ensure => 'latest' }
    $package_provider = 'yum'
  }
  default: {
    fail("Unsupported osfamily (${::osfamily})")
  }
}

#--------------------
# Deploy MySQL Server
#--------------------

class { '::mysql::server': }

#----------------
# Deploy RabbitMQ
#----------------

class { '::rabbitmq':
  delete_guest_user => true,
  package_provider  => $package_provider,
}
rabbitmq_vhost { '/':
  provider => 'rabbitmqctl',
  require  => Class['rabbitmq'],
}
rabbitmq_user { ['neutron', 'nova']:
  admin    => true,
  password => $rabbitmq_password,
  provider => 'rabbitmqctl',
  require  => Class['rabbitmq'],
}
rabbitmq_user_permissions { ['neutron@/', 'nova@/']:
  configure_permission => '.*',
  write_permission     => '.*',
  read_permission      => '.*',
  provider             => 'rabbitmqctl',
  require              => Class['rabbitmq'],
}

#----------------
# Deploy Keystone
#----------------

class { '::keystone::client': }
class { '::keystone::cron::token_flush': }
class { '::keystone::db::mysql':
  password      => $keystone_db_password,
  allowed_hosts => '%',
}

class { '::keystone':
  verbose             => true,
  debug               => true,
  catalog_type        => 'sql',
  admin_token         => $keystone_admin_token,
  token_provider      => 'keystone.token.providers.uuid.Provider',
  token_driver        => 'keystone.token.persistence.backends.sql.Token',
  database_connection => "mysql://keystone:${keystone_db_password}@${keystone_db_host}/keystone",
  enabled             => true,
  service_name        => 'httpd',
  default_domain      => 'default_domain',
}

include ::apache

class { '::keystone::wsgi::apache':
  ssl => false,
}

class { '::keystone::roles::admin':
  email    => 'test@example.tld',
  password => $keystone_admin_password,
  admin_tenant => 'admin',
}

class { '::keystone::endpoint':
  default_domain => 'admin',
}

#--------------
# Deploy Glance
#--------------

class { '::glance::db::mysql':
  password      => $glance_db_password,
  allowed_hosts => '%',
}

include ::glance
include ::glance::client

class { '::glance::keystone::auth':
  password => $keystone_admin_password,
}

class { '::glance::api':
  debug               => true,
  verbose             => true,
  database_connection => "mysql://glance:${glance_db_password}@${glance_db_host}/glance?charset=utf8",
  keystone_password   => $keystone_admin_password,
}

class { '::glance::registry':
  debug               => true,
  verbose             => true,
  database_connection => "mysql://glance:${glance_db_password}@${glance_db_host}/glance?charset=utf8",
  keystone_password   => $keystone_admin_password,
}

# MidoNet API setup
#------------------

$mido_repo = $operatingsystem ? {
  'CentOS' => 'http://repo.midonet.org/midonet/v2015.06/RHEL',
  'Ubuntu' => 'http://repo.midonet.org/midonet/v2015.06'
}

class {'::midonet::repository':
  midonet_repo       => $mido_repo,
  openstack_release  => $openstack_release,
} ->

class {'::midonet::midonet_api':
  zk_servers           => [{'ip'   => 'host1', 'port' => '2181'}],
  keystone_auth        => true,
  keystone_host        => 'localhost',
  keystone_admin_token => $keystone_admin_password,
  keystone_tenant_name => 'admin',
#  bind_address         => $::ipaddress_br_mgmt,
  api_ip               => 'localhost',
  api_port             => '8080',
  require              => Class['::midonet::repository']
}


#---------------
# Deploy Neutron
#---------------

class { '::neutron::db::mysql':
  password      => $neutron_db_password,
  allowed_hosts => '%',
}

class { '::neutron::keystone::auth':
  password => $keystone_admin_password,
}

class { '::neutron':
  rabbit_user           => 'neutron',
  rabbit_password       => $rabbitmq_password,
  rabbit_host           => '127.0.0.1',
  allow_overlapping_ips => true,
  core_plugin           => 'midonet.neutron.plugin.MidonetPluginV2',
  service_plugins       => ['router', 'metering'],
  debug                 => true,
  verbose               => true,
}

class { '::neutron::client': }

class { '::neutron::server':
  database_connection => "mysql://neutron:${neutron_db_password}@${neutron_db_host}/neutron?charset=utf8",
  auth_password       => $keystone_admin_password,
  identity_uri        => 'http://127.0.0.1:35357/',
  sync_db             => true,
}

#class { 'neutron::plugins::midonet':
#  midonet_api_ip    => 'localhost',
#  midonet_api_port  => '8080',
#  keystone_username => 'neutron',
#  keystone_password => '32kjaxT0k3na',
#  keystone_tenant   => 'services',
#  sync_db           => true
#} ->

class { '::neutron::agents::dhcp':
  debug                    => false,
  interface_driver         => 'neutron.agent.linux.interface.MidonetInterfaceDriver',
  dhcp_driver              => 'midonet.neutron.agent.midonet_driver.DhcpNoOpDriver',
  enable_isolated_metadata => true,
  enabled                  => true,
}

class { '::neutron::agents::metering':
  debug => false,
}

class { '::neutron::server::notifications':
  nova_admin_password => $keystone_admin_password,
}

#------------
# Deploy Nova
#------------

class { '::nova::db::mysql':
  password      => 'nova',
  allowed_hosts => '%',
}

class { '::nova::keystone::auth':
  password => $keystone_admin_password,
}

class { '::nova':
  database_connection => "mysql://nova:${nova_db_password}@${nova_db_host}/nova?charset=utf8",
  rabbit_host         => '127.0.0.1',
  rabbit_userid       => 'nova',
  rabbit_password     => $rabbitmq_password,
  glance_api_servers  => 'localhost:9292',
  verbose             => true,
  debug               => true,
}

class { '::nova::api':
  admin_password                       => $keystone_admin_password,
  identity_uri                         => 'http://127.0.0.1:35357/',
  osapi_v3                             => true,
  neutron_metadata_proxy_shared_secret => $keystone_admin_password,
}

class { '::nova::cert': }
class { '::nova::client': }
class { '::nova::conductor': }
class { '::nova::consoleauth': }
class { '::nova::cron::archive_deleted_rows': }
class { '::nova::compute': vnc_enabled => true }

class { '::nova::compute::libvirt':
  libvirt_virt_type => 'qemu',
  migration_support => true,
  vncserver_listen  => '0.0.0.0',
}

class { '::nova::scheduler': }
class { '::nova::vncproxy': }

class { '::nova::network::neutron':
  neutron_admin_password => $keystone_admin_password,
  neutron_admin_auth_url => 'http://127.0.0.1:35357/v2.0',
}

}


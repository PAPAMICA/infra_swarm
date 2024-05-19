# Define required providers
terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "1.54.1"
    }
  }
}

# Configure the OpenStack Provider
provider "openstack" {
  auth_url = "https://api.pub1.infomaniak.cloud/identity"
  region = "dc3-a"
  user_name = var.user_name
  password = var.password
  user_domain_name = "Default"
  project_domain_id = "default"
  tenant_id = var.tenant_id
  tenant_name = var.tenant_name
}

# Upload public key
resource "openstack_compute_keypair_v2" "yubikey" {
  name = var.keypair_name
  public_key = var.ssh_key
}   

# Create router
resource "openstack_networking_router_v2" "front_router" {
  name = "front-router"
  admin_state_up      = true
  external_network_id = var.floating_ip_pool_id
}

resource "openstack_networking_router_interface_v2" "front_router" {
  depends_on = ["openstack_networking_subnet_v2.private_subnet", "openstack_networking_router_v2.front_router"]
  router_id = openstack_networking_router_v2.front_router.id
  subnet_id = openstack_networking_subnet_v2.private_subnet.id
}


# Add subnet
resource "openstack_networking_network_v2" "private_network" {
  name           = "private_network"
  admin_state_up = "true"
}

resource "openstack_networking_subnet_v2" "private_subnet" {
  name       = "private_subnet"
  network_id = openstack_networking_network_v2.private_network.id
  cidr       = "10.10.0.0/24"
  dns_nameservers = ["9.9.9.9","1.1.1.1"]
  ip_version = 4
  enable_dhcp = true
  allocation_pool {
    start = "10.10.0.101"
    end   = "10.10.0.200"
  }
}


resource "openstack_networking_secgroup_v2" "ssh_external" {
  name        = "SSH-EXTERNAL"
  description = "Security group for SSH external access."
}

resource "openstack_networking_secgroup_rule_v2" "ssh_external" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.ssh_external.id
}

resource "openstack_networking_secgroup_v2" "ssh_internal" {
  name        = "SSH-INTERNAL"
  description = "Security group for SSH internal access."
}

resource "openstack_networking_secgroup_rule_v2" "ssh_internal" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "10.10.0.0/24"
  security_group_id = openstack_networking_secgroup_v2.ssh_internal.id
}

resource "openstack_networking_secgroup_rule_v2" "http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.ssh_internal.id
}



resource "openstack_networking_secgroup_rule_v2" "docker_swarm" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 2377
  port_range_max    = 2377
  remote_ip_prefix  = "10.10.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.ssh_internal.id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.ssh_internal.id
}

resource "openstack_networking_secgroup_rule_v2" "icmp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.ssh_internal.id
}

### MANAGMENT INSTANCE ###
resource "openstack_compute_instance_v2" "Managment" {
  depends_on = [
    "openstack_networking_subnet_v2.private_subnet",
    "openstack_compute_instance_v2.Workers",
    "openstack_compute_instance_v2.managers"
  ]
  count = var.managment_num
  name = "managment-${count.index + 1}"
  image_id = var.managment_image
  flavor_id = var.managment_flavor
  key_pair = var.keypair_name
  security_groups = [openstack_networking_secgroup_v2.ssh_external.name, openstack_networking_secgroup_v2.ssh_internal.name]
  network {
    name = "private_network"
    fixed_ip_v4 = "10.10.0.20${count.index + 1}"    
  }
  user_data =  <<-EOT
#!/bin/bash
sudo useradd -m -s /bin/bash ${var.managment_user}
sudo usermod -aG sudo ${var.managment_user}
mkdir /home/${var.managment_user}/.ssh
echo "${var.ssh_key}" >> /home/${var.managment_user}/.ssh/authorized_keys
su - ${var.managment_user}
cd /home/${var.managment_user}/
sudo apt update
sudo apt install -y ansible
echo -e 'all:
  children:
    managers:
      hosts:
${join("\n", [for instance in openstack_compute_instance_v2.managers : "        ${instance.network.0.fixed_ip_v4}:"])}
    workers:
      hosts:
${join("\n", [for instance in openstack_compute_instance_v2.Workers : "       ${instance.network.0.fixed_ip_v4}:"])}
' > ~/inventory.yml
git clone https://github.com/PAPAMICA/infra_swarm.git
  EOT


}

resource "openstack_networking_floatingip_v2" "fip" {
  pool = var.floating_ip_pool
}

resource "openstack_compute_floatingip_associate_v2" "fip_managment" {
  depends_on = ["openstack_networking_floatingip_v2.fip"]
  floating_ip = openstack_networking_floatingip_v2.fip.address
  instance_id = openstack_compute_instance_v2.Managment[0].id
}


### manager INSTANCES ###
resource "openstack_compute_instance_v2" "managers" {
  depends_on = ["openstack_networking_subnet_v2.private_subnet"]
  count = var.manager_num
  name = "manager-${count.index + 1}"
  image_id = var.managment_image
  flavor_id = var.manager_flavor
  key_pair = var.keypair_name
  security_groups = [openstack_networking_secgroup_v2.ssh_internal.name]
  network {
    name = "private_network"
    fixed_ip_v4 = "10.10.0.1${count.index + 1}"
  }
  user_data = file("bootstrap/manager.sh")
}

resource "openstack_blockstorage_volume_v3" "managers" {
  depends_on = ["openstack_compute_instance_v2.managers"]
  count = var.manager_num
  name = "manager_storage-${count.index + 1}"
  size = var.manager_volume_size
}

resource "openstack_compute_volume_attach_v2" "managers" {
  depends_on = ["openstack_blockstorage_volume_v3.managers"]
  count       = var.manager_num
  instance_id = openstack_compute_instance_v2.managers[count.index].id
  volume_id   = openstack_blockstorage_volume_v3.managers[count.index].id
}


### WORKER INSTANCES ###
resource "openstack_compute_instance_v2" "Workers" {
  depends_on = ["openstack_networking_subnet_v2.private_subnet"]
  count = var.worker_num
  name = "worker-${count.index + 1}"
  image_id = var.managment_image
  flavor_id = var.worker_flavor
  key_pair = var.keypair_name
  security_groups = [openstack_networking_secgroup_v2.ssh_internal.name]
  network {
    name = "private_network"
    fixed_ip_v4 = "10.10.0.5${count.index + 1}"
  }
  user_data = file("bootstrap/worker.sh")
}

resource "openstack_blockstorage_volume_v3" "Workers" {
  depends_on = ["openstack_compute_instance_v2.Workers"]
  count = var.worker_num
  name = "worker_storage-${count.index + 1}"
  size = var.worker_volume_size
}

resource "openstack_compute_volume_attach_v2" "Workers" {
  depends_on = ["openstack_blockstorage_volume_v3.Workers"]
  count       = var.worker_num
  instance_id = openstack_compute_instance_v2.Workers[count.index].id
  volume_id   = openstack_blockstorage_volume_v3.Workers[count.index].id
}

output "Managment_ip" {
    value = openstack_compute_floatingip_associate_v2.fip_managment.floating_ip
    }

output "All_instance_ips" {
  value = {
    for instance_type, instances in {
      Managment = openstack_compute_instance_v2.Managment,
      managers = openstack_compute_instance_v2.managers,
      Workers = openstack_compute_instance_v2.Workers
    } : instance_type => [for instance in instances : instance.network.0.fixed_ip_v4]
  }
}